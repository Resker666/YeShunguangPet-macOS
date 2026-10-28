import Foundation
import Combine
import PetCore

struct VoiceDraftSnapshot: Equatable {
    let character: ChatCharacter
    let revision: UInt64
    let text: String
}
enum ChatVoiceSurface: Equatable { case hidden, conversation, settings, other }
struct VoiceEnvironment: Equatable {
    var surface: ChatVoiceSurface = .hidden
    var blocked = false, effectiveQuiet = false, sleeping = false, terminating = false, disposed = false
}
struct VoiceSavedReply {
    let id: UUID
    let context: ChatCharacter
    let requestRevision: UInt64
    let text: String
}
enum VoiceCaptureState: Equatable { case idle, stoppingOutput, requestingPermissions, recording, finishing }

@MainActor final class ChatVoiceController: ObservableObject {
    @Published private var changeRevision: UInt64 = 0
    let settings: ChatVoicePreferencesController
    private let services: VoiceServices, now: () -> Duration
    private let draft: () -> VoiceDraftSnapshot?, canRecognize: () -> Bool
    private let apply: (VoiceDraftSnapshot, VoiceInsertion) -> Bool
    private let resolveSelection: @MainActor (ChatCharacter) async -> VoiceRouteSelection
    private let canUseServices: @MainActor () -> Bool
    private var environment = VoiceEnvironment(), disposed = false
    private struct Capture {
        let token: UUID, snapshot: VoiceDraftSnapshot, selection: NSRange, mode: VoiceRecognitionMode
    }
    private var capture: Capture?, previewCapture: Capture?
    private var activity: UUID?, outputToken: UUID?, outputContext: ChatCharacter?
    private var outputSurface: ChatVoiceSurface?
    private var preparation: Task<Void, Never>?
    private var outputStop: Task<Bool, Never>?
    private var stopToken: UUID?
    private var commandRevision: UInt64 = 0
    private var deadline: Duration?
    private var lastReplyRevision: UInt64 = 0
    private var settingsObservation: AnyCancellable?
    private lazy var scheduler = FrameScheduler(now: now) { [weak self] in self?.serviceDeadlines() }
    private(set) var captureState: VoiceCaptureState = .idle
    private(set) var preview = "", error: String?
    private(set) var isSpeaking = false, canOfferNetwork = false
    private(set) var isStoppingOutput = false, outputStopFailed = false
    private static let stopFailureMessage = "语音输出尚未确认停止，可能仍在生成或播放。请重试停止；新录音或朗读须先确认输出已停止。"
    private(set) var actualVoice: SystemVoice?
    private(set) var actualOutput: VoiceOutputIdentity?
    private(set) var outputPhase: VoiceOutputPhase = .idle
    private(set) var availableVoices = [SystemVoice]()
    var blocksChat: Bool { captureState != .idle }
    var suppressesCompletionAudio: Bool { captureState == .recording || captureState == .finishing }
    var outputStatus: String? {
        switch outputPhase {
        case .idle: return nil
        case .resolving: return "正在读取角色音色"
        case .starting: return "正在启动语音输出"
        case .generating: return "正在生成本地语音，可停止"
        case .playing: return "正在朗读" + (actualOutput.map { " · " + $0.displayName + ($0.backend == .local ? " · 本地角色音色" : " · 系统音色") } ?? "")
        case .stopping: return "正在确认语音输出已停止并清理资源"
        }
    }
    var hasOutputActivity: Bool { outputToken != nil || (outputContext != nil && preparation != nil) }
    var hasPendingResources: Bool { outputStop != nil || services.output.hasResources }
    private var hasCancellableActivity: Bool { blocksChat || hasOutputActivity || preparation != nil || !preview.isEmpty || canOfferNetwork || (services.output.hasResources && !isStoppingOutput && !outputStopFailed) }
    var hasActivity: Bool { hasCancellableActivity || isStoppingOutput || outputStopFailed }
    init(settings: ChatVoicePreferencesController, services: VoiceServices, now: @escaping () -> Duration,
         draft: @escaping () -> VoiceDraftSnapshot?, canRecognize: @escaping () -> Bool,
         apply: @escaping (VoiceDraftSnapshot, VoiceInsertion) -> Bool,
         resolveSelection: @escaping @MainActor (ChatCharacter) async -> VoiceRouteSelection = { _ in .system },
         canUseServices: @escaping @MainActor () -> Bool = { true }) {
        self.settings = settings; self.services = services; self.now = now; self.draft = draft; self.canRecognize = canRecognize; self.apply = apply; self.resolveSelection = resolveSelection
        self.canUseServices = canUseServices
        availableVoices = Self.filter(services.output.installedSystemVoices())
        services.output.onVoicesChanged = { [weak self] in
            guard let self, !self.disposed else { return }
            self.availableVoices = Self.filter(self.services.output.installedSystemVoices())
            if self.actualOutput?.backend == .system, let selected = self.actualVoice, !self.availableVoices.contains(where: { $0.id == selected.id }), self.hasOutputActivity { self.stop() }
            self.changeRevision &+= 1
        }
        settings.onDisable = { [weak self] in self?.stop() }
        settingsObservation = settings.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.disposed else { return }
                if !settings.enabledForSession, self.hasCancellableActivity { self.stop() }
                self.changeRevision &+= 1
            }
        }
    }
    private static func filter(_ voices: [SystemVoice]) -> [SystemVoice] {
        voices.filter { $0.isAppleVoice && !$0.isPersonalVoice && $0.language.lowercased().hasPrefix("zh") }
    }
    private var usable: Bool { !disposed && !environment.disposed && !environment.sleeping && !environment.terminating && !environment.blocked && settings.enabledForSession && canUseServices() }
    private func inputAllowed() -> Bool { usable && environment.surface == .conversation && canRecognize() }
    private func current(_ value: Capture) -> Bool {
        activity == value.token && capture?.token == value.token && inputAllowed() && draft() == value.snapshot
    }
    func beginInput(selection: NSRange) { beginInput(selection: selection, mode: .onDevice) }
    func allowNetworkForThisRecording(selection: NSRange) {
        guard canOfferNetwork else { return }
        beginInput(selection: selection, mode: .allowNetwork)
    }
    private func beginInput(selection: NSRange, mode: VoiceRecognitionMode) {
        guard !blocksChat, inputAllowed(), let snapshot = draft() else { return }
        let command = commandRevision &+ 1
        stop()
        let barrier = outputStop
        guard commandRevision == command, inputAllowed(), draft() == snapshot else { return }
        let value = Capture(token: UUID(), snapshot: snapshot, selection: selection, mode: mode)
        activity = value.token; capture = value; previewCapture = value
        error = nil; canOfferNetwork = false; captureState = .stoppingOutput
        changeRevision &+= 1
        guard current(value) else { return }
        preparation = Task { [weak self] in
            guard let self else { return }
            let stopped = await barrier?.value ?? false
            guard !Task.isCancelled, self.current(value) else { return }
            guard stopped else { self.failCapture(value, message: VoiceOutputFailure.busy.localizedDescription); return }
            self.captureState = .requestingPermissions; self.changeRevision &+= 1
            guard self.current(value) else { return }
            let permissions = await self.services.input.requestPermissions()
            guard !Task.isCancelled, self.current(value) else { return }
            guard permissions.isAuthorized else { self.failCapture(value, message: VoiceInputFailure.permissionDenied.localizedDescription); return }
            let available = self.services.input.availability()
            guard self.current(value) else { return }
            guard mode != .onDevice || available.supportsOnDevice else {
                self.failCapture(value, message: VoiceInputFailure.onDeviceUnavailable.localizedDescription, offerNetwork: true); return
            }
            guard available.isAvailable else { self.failCapture(value, message: VoiceInputFailure.serviceUnavailable.localizedDescription, offerNetwork: mode == .onDevice); return }
            self.captureState = .recording; self.deadline = self.now() + .seconds(45)
            self.scheduler.schedule(after: .seconds(45)); self.changeRevision &+= 1
            guard self.current(value) else { return }
            do {
                try self.services.input.start(token: value.token, mode: mode) { [weak self] token, event in self?.receiveInput(token, event) }
                if self.activity == value.token { self.preparation = nil }
            } catch {
                guard self.current(value) else { return }
                let failure = error as? VoiceInputFailure ?? .recognitionFailed
                self.failCapture(value, message: failure.localizedDescription, offerNetwork: mode == .onDevice && [.onDeviceUnavailable, .recognitionFailed, .serviceUnavailable].contains(failure))
            }
        }
    }
    private func retireCapture() {
        let token = capture?.token
        capture = nil; captureState = .idle; deadline = nil; scheduler.cancel()
        if let token { services.input.cancel(token: token) }
    }
    private func failCapture(_ value: Capture, message: String, offerNetwork: Bool = false) {
        guard capture?.token == value.token else { return }
        preparation = nil; retireCapture(); error = message; canOfferNetwork = offerNetwork; changeRevision &+= 1
    }
    func finishInput() {
        guard let value = capture, captureState == .recording, current(value) else { return }
        captureState = .finishing; deadline = now() + .seconds(5); scheduler.schedule(after: .seconds(5)); changeRevision &+= 1
        guard current(value), captureState == .finishing else { return }
        services.input.finish(token: value.token)
    }
    func serviceDeadlines() {
        guard let deadline, now() >= deadline else { return }
        if captureState == .recording { finishInput() }
        else if captureState == .finishing, let value = capture {
            failCapture(value, message: "等待最终识别超时。已有预览尚未加入草稿，可检查后手动接受，或重新录音。")
        }
    }
    private func receiveInput(_ token: UUID, _ event: VoiceInputEvent) {
        guard let value = capture, value.token == token else { return }
        guard current(value) else { cancelInput(); error = "角色或草稿已变化，本次识别未加入草稿。"; changeRevision &+= 1; return }
        switch event {
        case .partial(let text):
            if text.utf16.count <= 2000 { preview = text; changeRevision &+= 1 }
            else { failCapture(value, message: "识别文字超过 2000 个 UTF-16 单元，未加入草稿。") }
        case .final(let text):
            do { try ChatText.validate(text, maxUTF16: 2000, allowEmpty: false) }
            catch { failCapture(value, message: "最终识别为空或超过文字上限，未加入草稿；可检查已有预览。 "); return }
            preview = text; preparation = nil; retireCapture()
            acceptPreview()
        case .failed(let failure):
            failCapture(value, message: failure.localizedDescription, offerNetwork: value.mode == .onDevice && [.onDeviceUnavailable, .serviceUnavailable, .recognitionFailed].contains(failure))
        }
    }
    func acceptPreview() {
        guard !blocksChat, inputAllowed(), let value = previewCapture, draft() == value.snapshot, !preview.isEmpty else { return }
        do {
            let insertion = try VoiceText.inserting(preview, into: value.snapshot.text, replacing: value.selection)
            let token = activity
            previewCapture = nil
            if apply(value.snapshot, insertion) {
                if activity == token { preview = ""; error = nil; canOfferNetwork = false }
            } else if activity == token { error = "草稿已变化，本次预览未加入草稿。" }
        } catch { self.error = "合并识别文字后超过输入上限或含有无效字符，草稿保持原状。" }
        changeRevision &+= 1
    }
    func cancelInput() { stop() }
    func didSaveReply(_ reply: VoiceSavedReply) {
        guard reply.requestRevision > lastReplyRevision else { return }
        lastReplyRevision = reply.requestRevision
        guard settings.preferences.automaticReadAloud, reply.context == draft()?.character,
              usable, environment.surface == .conversation, !environment.effectiveQuiet, !blocksChat else { return }
        read(VoiceText.automaticExcerpt(reply.text), surface: .conversation)
    }
    func readLatest(_ text: String) { read(text, surface: .conversation) }
    func previewVoice() { read("你好，我在这里。我们一起度过专注的一天。", surface: .settings) }
    private func read(_ text: String, surface: ChatVoiceSurface) {
        guard usable, environment.surface == surface, !environment.effectiveQuiet, !blocksChat, let context = draft()?.character else {
            error = environment.effectiveQuiet ? "当前处于安静模式，请先关闭安静再朗读。" : "当前状态无法朗读，请检查语音开关、对话页与阻挡窗口。"; changeRevision &+= 1; return
        }
        do { try ChatText.validate(text, maxUTF16: 8000, allowEmpty: false) }
        catch { self.error = "没有可朗读的已保存文字，或文字超过上限。"; changeRevision &+= 1; return }
        availableVoices = Self.filter(services.output.installedSystemVoices())
        // A new sentence may reuse a confirmed idle role model. Explicit stop,
        // recording and lifecycle changes still dispose of the idle worker.
        let command = commandRevision &+ 1
        if hasOutputActivity || outputStopFailed, outputStop == nil { stop() }
        else {
            commandRevision &+= 1; activity = nil; preparation?.cancel(); preparation = nil
            retireCapture(); previewCapture = nil; preview = ""; canOfferNetwork = false
            outputToken = nil; outputContext = nil; outputSurface = nil; isSpeaking = false
        }
        let barrier = outputStop
        guard commandRevision == command, usable, environment.surface == surface, !environment.effectiveQuiet, draft()?.character == context else { return }
        let token = UUID(); activity = token; outputToken = token; outputContext = context; outputSurface = surface
        actualVoice = nil; actualOutput = nil; error = nil; outputPhase = .resolving
        changeRevision &+= 1
        guard outputValid(token, context: context, surface: surface, command: command) else { return }
        preparation = Task { [weak self] in
            guard let self else { return }
            let stopped = await barrier?.value ?? true
            guard !Task.isCancelled, self.outputValid(token, context: context, surface: surface, command: command) else { return }
            guard stopped else { self.failOutput(token, issue: .stopping); return }
            let selection = await self.resolveSelection(context)
            guard !Task.isCancelled, self.outputValid(token, context: context, surface: surface, command: command) else { return }
            let prepared = await self.services.output.prepare(for: selection)
            guard !Task.isCancelled, self.outputValid(token, context: context, surface: surface, command: command) else { return }
            guard prepared else { self.failOutput(token, issue: .stopping); return }
            self.preparation = nil
            do {
                let request = RoutedVoiceRequest(token: token, text: text, rate: self.settings.preferences.rate,
                                                preferredSystemVoiceID: self.settings.preferences.voiceIdentifier, selection: selection,
                                                isValid: { [weak self] in self?.outputValid(token, context: context, surface: surface, command: command) == true })
                try self.services.output.speak(request) { [weak self] token, event in self?.receiveOutput(token, event) }
            } catch {
                guard self.outputToken == token else { return }
                self.failOutput(token, issue: error as? LocalVoiceIssue ?? .systemUnavailable)
            }
        }
    }
    private func outputValid(_ token: UUID, context: ChatCharacter, surface: ChatVoiceSurface, command: UInt64) -> Bool {
        outputToken == token && activity == token && commandRevision == command && usable && environment.surface == surface && !environment.effectiveQuiet && !blocksChat && draft()?.character == context
    }
    private func failOutput(_ token: UUID, issue: LocalVoiceIssue) {
        guard outputToken == token else { return }
        outputToken = nil; preparation = nil; isSpeaking = false
        if !services.output.hasResources { outputContext = nil; outputSurface = nil }
        outputPhase = issue == .stopping ? .stopping : .idle
        outputStopFailed = issue == .stopping
        error = issue == .stopping ? Self.stopFailureMessage : issue.localizedDescription
        changeRevision &+= 1
    }
    private func receiveOutput(_ token: UUID, _ event: RoutedVoiceEvent) {
        guard outputToken == token else { return }
        switch event {
        case .phase(let phase): outputPhase = phase; isSpeaking = phase == .playing
        case .actualIdentity(let identity):
            actualOutput = identity; actualVoice = availableVoices.first { $0.id == identity.systemVoiceID }
        case .notice(let message): error = message
        case .failed(let issue): failOutput(token, issue: issue); return
        case .finished, .cancelled:
            // Keep the owner while a warm model remains, so even an idle worker
            // is invalidated by a same-ID skin replacement or page transition.
            outputToken = nil; isSpeaking = false; outputPhase = .idle
            if !services.output.hasResources { outputContext = nil; outputSurface = nil }
        }
        changeRevision &+= 1
    }
    func stop() {
        commandRevision &+= 1
        activity = nil; preparation?.cancel(); preparation = nil
        retireCapture(); previewCapture = nil; preview = ""; canOfferNetwork = false
        outputToken = nil; outputContext = nil; outputSurface = nil; isSpeaking = false; actualVoice = nil; actualOutput = nil; outputPhase = .stopping
        let output = services.output, previous = outputStop, stopID = UUID()
        stopToken = stopID; isStoppingOutput = true
        outputStop = Task { [weak self] in
            if let previous { _ = await previous.value }
            let result = await output.stop()
            if let self, self.stopToken == stopID {
                self.outputStop = nil
                if !self.disposed {
                    self.isStoppingOutput = false; self.outputStopFailed = !result; self.outputPhase = result ? .idle : .stopping
                    if !result { self.error = Self.stopFailureMessage }
                    else if self.error == Self.stopFailureMessage { self.error = nil }
                    self.changeRevision &+= 1
                }
            }
            return result
        }
        changeRevision &+= 1
    }
    func stopAndWait() async -> Bool {
        if let outputStop { return await outputStop.value }
        stop()
        return await outputStop?.value ?? false
    }
    func updateEnvironment(_ snapshot: VoiceEnvironment) {
        environment = snapshot
        let contextChanged = capture.map { draft() != $0.snapshot } == true || outputContext.map { draft()?.character != $0 } == true
        let outputPageChanged = outputSurface.map { $0 != snapshot.surface } == true
        if contextChanged || outputPageChanged || !usable || (snapshot.surface != .conversation && (blocksChat || !preview.isEmpty || canOfferNetwork)) || snapshot.surface == .hidden || snapshot.surface == .other {
            if hasCancellableActivity { stop() }
        } else if snapshot.effectiveQuiet && (hasOutputActivity || (preparation != nil && capture == nil) || (services.output.hasResources && !isStoppingOutput && !outputStopFailed)) { stop() }
    }
    func dispose() {
        guard !disposed else { return }
        disposed = true; stop(); services.output.onVoicesChanged = nil; settingsObservation?.cancel(); settingsObservation = nil; settings.dispose()
    }
}
