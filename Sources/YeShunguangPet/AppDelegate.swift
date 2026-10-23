import AppKit
import PetCore
import Darwin

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: PetSession?
    var status: StatusBarController?
    private var terminationSignal: DispatchSourceSignal?
    private var terminationPending=false
    private func trace(_ message: String) {
        if ProcessInfo.processInfo.environment["YSGPET_METRICS_PATH"] != nil { NSLog("YSGPET: %@",message) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        trace("didFinishLaunching")
        signal(SIGTERM,SIG_IGN)
        let termination=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
        termination.setEventHandler { NSApp.terminate(nil) }; termination.resume(); terminationSignal=termination; trace("termination signal registered")
        do {
            let options=try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
            guard let url=Bundle.main.url(forResource:"pet",withExtension:"json",subdirectory:"Pets/YeShunguang") else { throw SkinError("缺少随附皮肤 pet.json") }
            let bundled=try SkinLoader.load(manifestURL:url)
            let skin=try options.skinURL.map { try SkinLoader.load(manifestURL:$0) } ?? bundled
            let clock=ContinuousClock(), origin=ContinuousClock.now
            let settingsURL: URL
            if let path=ProcessInfo.processInfo.environment["YSGPET_SETTINGS_PATH"],path.hasPrefix("/") { settingsURL=URL(fileURLWithPath:path) }
            else { settingsURL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("YeShunguangPet-macOS/settings.json") }
            let session=PetSession(skin:skin,defaultSkin:bundled,now:{origin.duration(to:clock.now)},settings:SettingsStore(url:settingsURL),screens:ScreenProvider.areas)
            self.session=session; status=StatusBarController(session:session,onQuit:{ NSApp.terminate(nil) }); session.start(restoringSkin:options.skinURL==nil); status?.startShortcuts(); trace("runtime ready")
        } catch { status=StatusBarController(session:nil,error:error.localizedDescription,onQuit:{NSApp.terminate(nil)}) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        status?.beginTermination()
        let model=status?.skinModel
        let chat=status?.chat
        if model?.hasPendingMutation == true || chat?.hasPendingWrites == true || chat?.terminationSaveError != nil {
            terminationPending=true
            Task {
                await model?.waitForPendingMutations()
                await chat?.waitForPendingWrites()
                let chatProceed=await confirmChatTermination(chat)
                let proceed=chatProceed && confirmTermination(model:model)
                if !proceed { status?.cancelTermination() }
                terminationPending=false
                sender.reply(toApplicationShouldTerminate:proceed)
            }
            return .terminateLater
        }
        let proceed=confirmTermination(model:model)
        if !proceed { status?.cancelTermination() }
        return proceed ? .terminateNow : .terminateCancel
    }
    private func confirmChatTermination(_ chat:ChatController?) async -> Bool {
        guard let chat else { return true }
        while let message=chat.terminationSaveError {
            let alert=NSAlert(); alert.messageText="聊天资料尚未保存"; alert.informativeText=message
            let canRetry=chat.canRetryTerminationSave
            if canRetry { alert.addButton(withTitle:"重试本地保存") }
            alert.addButton(withTitle:"继续退出"); alert.addButton(withTitle:"取消退出")
            let answer=alert.runModal()
            if canRetry, answer == .alertFirstButtonReturn { _ = await chat.retryAllPendingSaves(); continue }
            return answer == (canRetry ? .alertSecondButtonReturn : .alertFirstButtonReturn)
        }
        return true
    }
    private func confirmTermination(model: SettingsModel?) -> Bool {
        if let error=model?.terminationCleanupError {
            let alert=NSAlert(); alert.messageText="皮肤副本未能清理"; alert.informativeText=error
            alert.addButton(withTitle:"继续退出"); alert.addButton(withTitle:"取消")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        guard let session,!session.requestExit() else { return true }
        let alert=NSAlert(); alert.messageText="设置未能保存"; alert.informativeText=session.persistenceError ?? "原配置保持不变。"
        alert.addButton(withTitle:"继续退出"); alert.addButton(withTitle:"取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let path=ProcessInfo.processInfo.environment["YSGPET_METRICS_PATH"],path.hasPrefix("/") {
            do { try session?.exportMetrics(to:URL(fileURLWithPath:path)) }
            catch { NSLog("运行指标未能写入：%@",error.localizedDescription) }
        }
        session?.prepareToExit(); status?.dispose(); terminationSignal?.cancel(); terminationSignal=nil
    }
}
