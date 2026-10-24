# 系统中文语音交流 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付0.5.0/build27，让用户主动录音、检查文字后发送，并用系统中文音色朗读完整回复，保留既有聊天、记忆与操作确认规则。

**Architecture:** 唯一ChatController组合共享语音控制器，轻/完整窗只呈现状态与命令。Apple Speech/AVAudioEngine和AVSpeechSynthesizer封装为可替换的原生服务，独立voice.json复用原AI后台工作者与FIFO；所有异步结果均绑定角色和活动代次，声音不参与聊天执行或存档判断。

**Tech Stack:** Swift6、AppKit、Foundation、Combine、Speech、AVFoundation/AVFAudio、XCTest；macOS14+，无第三方依赖。

**Spec:** [已批准书面设计](../specs/2026-10-24-macos-system-voice-chat-design.md)。用户于2026-10-24明确「认可书面设计，进入实施计划」。当前计划待审核，尚未授权产品实施。

## Global Constraints

- 仓库 `/Users/resker/develop/github/YeShunguangPet-macOS`，本地分支 `codex/macos-system-voice-chat`，产品基线 `0ae7f82c56fbb4481ce4ed28fc57802bb9e98bf2`；不额外建工作树，Windows/Minimal Sleep只读，真实皮肤JSON/PNG原字节不变。
- 用户已选本会话Native实施、最后一次独立整体评审，不重新询问执行方式，不逐任务派实现者/评审者；主执行者连续TDD与本地提交。仅在本计划获准后使用executing-plans，恢复账本限定 `.superpowers/sdd/2026-10-24-macos-system-voice-chat/progress.md`，不修改其他计划账本。
- 版本0.5.0/build27，macOS14+；arm64日用，x86_64仅实验交叉构建。主schema13、角色v2、connection与Keychain标识保持；升级不改写已有AI档案，正常问答仍按原12轮规则保存。
- 语音默认关闭，自动朗读偏好默认true但受启用约束；首选音色nil、默认语速0.5（已只读查询本机AVSpeechUtteranceDefaultSpeechRate）；语速0.35–0.65。新voice.json为schemaVersion1，最大8192字节，音色ID最多256 UTF-16。
- 普通话zh-CN；录音最多45秒、结束后最多5秒等final；最终草稿保持原2000 UTF-16上限。自动朗读最多600 UTF-16、手动最近回复最多8000，截取不拆字素、不额外请求摘要。
- 本机识别强制requiresOnDeviceRecognition=true；不可用后只提示，用户明确选择才开始一段新的允许联网录音，选择不跨段/重开；不自动回退、重传旧录音或重试。允许联网标识不等于已验证Apple实际远端处理。
- 结束录音/权限授权/停顿不发送；识别结果先进入草稿。操作仍由原确认卡执行，模型、朗读、识别文字均不能直接确认或执行。
- 自动验证使用临时settingsURL/AI、假权限/音频/网络/凭据；不自动调用真实麦克风、合成发声、Apple/DeepSeek、正式Keychain或登录项，不解析个人聊天/记忆正文，不写音频或私人内容日志。
- 本机Swift6.4与云端Swift6.3.3的兼容需分别据实报告；未授权push时不能为验证编译而推送，云端结果保留待后续授权。未授权本版push、tag、草稿或Release。

## Review Focus

1. 较早启用写入晚回、随后禁用保存失败或重试，仍须立即且持续停用语音，不因旧回执复活；Task4用可控FIFO验证。
2. 选区落在emoji/组合字素内部，或者草稿编辑后改回原文及同ID换肤，不能拆字或让旧识别覆盖；Task1/5/6验证字素、修订和完整角色。
3. 本机识别已得到partial后失败，允许联网必须是一次新录音，旧partial不被上传/插入/自动发送；Task2/5验证模式、令牌与零额外请求。
4. 目标窗口因全局sheet或marked input拒绝呈现，旧窗应保留；正常交接不能产生中间false可见性而取消语音；Task7直接回归0.4已知Minor。
5. 现有canPlayCompletionSound同时被计时命令/配置方法复用；录音抑制声音须另加只影响播放的门控，不能禁掉计时操作或统计；Task8验证。

---

## File Structure

| 文件 | 责任 |
| --- | --- |
| `Sources/PetCore/Chat/{VoicePreferences,VoicePreferencesStore,VoiceText}.swift` | 有界偏好、独立原子存储、字素安全插入与朗读截取 |
| `Sources/YeShunguangPet/Chat/Voice/VoiceServices.swift` | 识别/权限/合成协议、可发送值和错误分类 |
| `Sources/YeShunguangPet/Chat/Voice/{NativeSpeechInput,NativeSpeechOutput}.swift` | 系统录音识别及中文合成，资源停止/回调隔离 |
| `Sources/YeShunguangPet/Chat/Voice/{ChatVoicePreferencesController,ChatVoiceController}.swift` | 偏好失败意图、单一语音状态、上下文/代次/截止与朗读门控 |
| `Sources/YeShunguangPet/Chat/Voice/{ChatVoiceControls,ChatVoiceSettingsView}.swift` | 双窗复用的原生语音按钮/预览、完整窗语音页 |
| `Sources/YeShunguangPet/Chat/{ChatPersistence,ChatController}.swift` | 扩展同一FIFO；有界草稿/反馈/生命周期接入，不改变原网络解析 |
| `Sources/YeShunguangPet/Chat/{ChatPresentationCoordinator,ChatWindowController,QuickChatWindowController}.swift` | 原子交接、实际语音呈现状态、输入选区与新页面 |
| `Sources/YeShunguangPet/{StatusBarController,FocusController}.swift`、`Sources/YeShunguangPet/Info.plist` | 组合语音、精确暂停门控、只影响声音的抑制及用途声明/版本 |
| `Tests/{PetCoreTests,PetMacTests}/`、`Tests/Support/{VoiceFixtures,ChatFixtures}.swift` | 核心存储/文本、原生适配/控制器/窗口、可控替身与原FIFO夹具 |
| `YeShunguangPet.xcodeproj/project.pbxproj`、`Tests/Distribution/test_distribution.py` | 显式登记所有新增源码/测试和系统框架，真实包的用途声明验证 |
| `README.md`、`TODO.md`、`AGENTS.md`、`docs/system-voice-chat-validation.md` | 用户说明、真实证据与未测边界；不提前填写通过 |

Mac新增源码同时进入App与未托管PetMacTests源阶段，Core与相应Core测试进入原target，VoiceFixtures加入PetMacTests。当前唯一ChatPersisting测试替身为Tests/Support/ChatFixtures.swift中的ControlledChatPersistence，唯一协议fake host在Tests/PetMacTests/ChatPresentationTests.swift；不得遗漏其穷尽switch及新增接口。

### Task 1: 有界语音偏好、文字和独立存储

**Files:** 创建三个Core文件与`Tests/PetCoreTests/{VoicePreferencesTests,VoicePreferencesStoreTests,VoiceTextTests}.swift`；修改Xcode登记。

**Interfaces:** `public struct VoicePreferences: Codable, Equatable, Sendable`，公开可编辑字段`enabled: Bool`、`automaticReadAloud: Bool`、`voiceIdentifier: String?`、`rate: Double`，公开初始化默认false/true/nil/0.5，`public func validate() throws`。`public struct VoiceInsertion: Equatable, Sendable`提供public let text:String、selection:NSRange及public init。`public enum VoiceText`提供public static `inserting(_ transcript: String, into draft: String, replacing selection: NSRange) throws -> VoiceInsertion`与`automaticExcerpt(_ text: String) -> String`。`public final class VoicePreferencesStore`公开`init(url: URL, write: ((Data, URL) throws -> Void)? = nil, backup: ((URL, URL) throws -> Void)? = nil)`及`load() -> ChatLoadResult<VoicePreferences>`、`save(_ value: VoicePreferences) throws`、`backupAndReset() throws -> VoicePreferences`。

- [ ] **Step 1: 写RED用例。** 在三个测试类分别钉住默认/非法值、坏文件保护和字素安全；保存失败必须保留旧字节，missing load不创建目录。核心断言：
  ```swift
  XCTAssertEqual(VoicePreferences(), .init(enabled: false, automaticReadAloud: true, voiceIdentifier: nil, rate: 0.5))
  let result = try VoiceText.inserting("你好", into: "a😀b", replacing: NSRange(location: 2, length: 0))
  XCTAssertEqual(result.text, "a你好😀b") // 零长度选区夹到当前完整字素开头
  XCTAssertEqual(result.selection, NSRange(location: 3, length: 0))
  XCTAssertLessThanOrEqual(VoiceText.automaticExcerpt(String(repeating: "😀", count: 400)).utf16.count, 600)
  ```
- [ ] **Step 2: 运行并观察RED。** `bash scripts/test.sh -only-testing:PetCoreTests/VoicePreferencesTests -only-testing:PetCoreTests/VoicePreferencesStoreTests -only-testing:PetCoreTests/VoiceTextTests`；应因新类型缺失或目标断言失败，工程登记错误单独修正，不当正确RED。
- [ ] **Step 3: 最小实现上述接口。** 复用ChatAtomicFile/StrictJSON；归档精确字段/类型/重复键/8KiB、普通文件、版本1和标识控制字符检查。VoicePreferences内存草稿允许先构造再validate，所有加载/保存/应用边界都校验。插入先按完整字素夹选区，再验证最终2000上限，空识别拒绝；自动截取<=600并优先最近句末，不能增加模型请求。
- [ ] **Step 4: 验证GREEN及边界。** 同命令；补0.35/0.65与越界、NaN/无穷、257ID、布尔当数值/未知字段、8192以上、链接、nil ID编码、原子失败、只备份voice.json；2000/2001、复合emoji/CRLF、越界/NSNotFound选区、空白和句末截取，不改变原ChatText与ChatInputSelection合同。
- [ ] **Step 5: 本地提交。** `git diff --check`与上述测试通过后，仅提交本任务文件，消息`feat: add bounded voice preferences and text handling`。

### Task 2: 服务合同与可取消的系统识别适配

**Files:** 创建`VoiceServices.swift`、`NativeSpeechInput.swift`、`Tests/Support/VoiceFixtures.swift`、`Tests/PetMacTests/NativeSpeechInputTests.swift`；修改Info.plist及Xcode登记。

**Interfaces:** Mac层定义`VoiceRecognitionMode: Equatable, Sendable { case onDevice, allowNetwork }`，以及均为Equatable/Sendable的`VoiceAuthorization`（notDetermined/authorized/denied/restricted）、`VoicePermissions`（microphone/speech与isAuthorized）、`VoiceInputAvailability`（isAvailable/supportsOnDevice）、`VoiceInputFailure`（无设备/格式/本机不可用/服务不可用/权限/中断/识别失败的本地分类）。`VoiceInputEvent: Equatable, Sendable`为partial(String)/final(String)/failed(VoiceInputFailure)。`@MainActor protocol VoiceInputProviding: AnyObject`暴露`permissionStatus() -> VoicePermissions`、`requestPermissions() async -> VoicePermissions`、`availability() -> VoiceInputAvailability`、`start(token: UUID, mode: VoiceRecognitionMode, onEvent: @escaping @MainActor (UUID, VoiceInputEvent) -> Void) throws`、`finish(token: UUID)`、`cancel(token: UUID)`。生产`NativeSpeechInput()`实现，测试`ControlledVoiceInput`记录请求、模式、finish/cancel，并允许挂起权限及发送旧令牌事件。

- [ ] **Step 1: 写RED。** NativeSpeechInputTests用注入的捕获/识别驱动计数及合成事件，不启动真实硬件；驱动注入作为本文件内部测试边界，不另起产品服务。断言`testInvalidInputFormatNeverInstallsTap`的零通道/零采样率均throws且installCount=0；`testCancelledPermissionTaskDoesNotAskSecondPermission`在requestPermissions任务取消、麦克风授权晚回后不再请求speech权限、startCount=0；`testFinishAndCancelAreIdempotent`的tap移除及endAudio至多一次；`testModeIsNeverSilentlyChanged`要求本机true、allowNetwork仅明确输入模式才为false、每次最多一个识别任务。`testAppManifestDeclaresBothVoicePurposes`在源Info.plist缺少两用途声明时断言失败，路径由测试源位置定位仓库，不读取测试Bundle自己的权限表。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/NativeSpeechInputTests`，预期新接口/适配缺失或上述资源断言失败。
- [ ] **Step 3: 实现原生适配。** lazy建立zh-CN recognizer；只在主动start链路请求两项权限，逐项await后检查取消；授权结果转为Sendable值再交MainActor。有效格式才装一个tap，音频线程只append当前request，不碰UI/写盘；共享request在停止/移除tap期间同步，finish停止输入后endAudio，cancel清除engine/tap/task/request。配置变化/服务不可用停止并发本地错误，不自行重建任务。partial/final/error在回调线程提取不可变文字与分类后再交MainActor，不跨actor传SFSpeechRecognitionResult/AVAudioPCMBuffer。
- [ ] **Step 4: 验证GREEN与声明。** 同命令；补首次final早于手动finish、finish后晚partial、连续cancel、设备切换、权限受限和识别错误不重试。Info.plist增加非空中文`NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`，解释主动录音、可编辑文字与可能的Apple处理；不使用AVAudioSession或新系统最低目标。测试默认使用驱动替身，不凭API可调用宣称实际识别通过。
- [ ] **Step 5: 本地提交。** diff检查及测试通过后提交`feat: add cancellable native speech recognition adapter`。

### Task 3: 系统中文合成与停止确认

**Files:** 创建`NativeSpeechOutput.swift`、`Tests/PetMacTests/NativeSpeechOutputTests.swift`；扩展VoiceServices/VoiceFixtures与Xcode登记。

**Interfaces:** `SystemVoice: Equatable, Sendable`提供id/name/language/isAppleVoice/isPersonalVoice；`VoiceOutputEvent: Sendable { case finished, cancelled, failed }`。`@MainActor protocol VoiceOutputProviding: AnyObject`含`installedVoices() -> [SystemVoice]`、`speak(_ text: String, voiceIdentifier: String, rate: Double, token: UUID, onEvent: @escaping @MainActor (UUID, VoiceOutputEvent) -> Void) throws`、`stop() async -> Bool`与`onVoicesChanged: (() -> Void)? { get set }`。`NativeSpeechOutput()`为生产实现；`ControlledVoiceOutput`提供spoken记录、可控stop结果/挂起、旧回调与音色更新。`struct VoiceServices { let input: any VoiceInputProviding; let output: any VoiceOutputProviding }`是后续唯一组合值。

- [ ] **Step 1: 写RED。** 注入合成器驱动，断言`testBusySpeakDoesNotQueueAndLateCancelKeepsNewToken`在仍输出/停止时拒绝第二段，确认静止后新段可开始，旧didCancel不结束新段；`testStopRequiresObservedStoppedState`不能仅凭stopSpeaking返回true报告停止，`testVoiceListExcludesPersonalAndNonAppleVoices`不要求额外授权；固定短句试音也不访问麦克风/网络。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/NativeSpeechOutputTests`，预期接口/实现缺失或队列、停止断言失败。
- [ ] **Step 3: 实现合成器适配。** 单一lazy AVSpeechSynthesizer；speak仅在已经静止时开始一段，输出/停止中则throws，不自动排队；Task5在每次新输出前await stop。rate使用Task1已验证范围；delegate提取令牌事件安全进MainActor。stop立即清队列并以isSpeaking=false/对应结束回调确认，最多等待1秒，未确认返回false，不能继续录音；这个有界等待不声称物理输出缓冲或环境回声已消除。订阅availableVoicesDidChangeNotification并移除observer，不访问Personal Voice或第三方提供者、不落盘音频。
- [ ] **Step 4: 验证GREEN与失败。** 同命令；补stop时本来已静止、重复stop、同步结束/晚回、无中文音色、已选音色缺失、不可用ID和服务错误；驱动替身完成停止/超时验证，生产框架路径实际可闻仍待用户体验。
- [ ] **Step 5: 本地提交。** diff与测试通过后提交`feat: add bounded system Chinese speech synthesis`。

### Task 4: 单一FIFO中的语音偏好与安全禁用

**Files:** 创建`ChatVoicePreferencesController.swift`和`Tests/PetMacTests/VoicePreferencesControllerTests.swift`；修改ChatPersistence、ChatFixtures、ChatPersistenceTests及Xcode登记。

**Interfaces:** ChatPersisting新增`loadVoicePreferences() async -> ChatLoadResult<VoicePreferences>`；ChatWriteOperation新增`voicePreferences(VoicePreferences)`、`resetVoicePreferences`，ChatStoredValue新增`voicePreferences(VoicePreferences)`。Worker的URL为settingsURL同级`AI/voice.json`。`@MainActor final class ChatVoicePreferencesController: ObservableObject`以`init(persistence: any ChatPersisting, writes: ChatWriteQueue, canMutate: @escaping () -> Bool = { true })`建立；读取属性`preferences`、`enabledForSession`、`isLoaded`、`isWriting`、`hasUnsaved`、`error`、`protection`；命令`apply(_ value: VoicePreferences)`、`disable()`、`retryPendingSave()`、`discardPendingSave()`、`backupAndReset()`、`dispose()`，回调`onDisable: (() -> Void)?`。它必须使用传入的原队列；dispose撤销未接受加载/新命令，已接受写入留给原FIFO。

- [ ] **Step 1: 写RED。** ControlledChatPersistence扩展voice加载与两操作名称（voicePreferences/resetVoicePreferences）。用holdNextWrite/failNext/releaseWrite，断言`testDisableSurvivesLateEnableReceiptAndFailedSave`立即enabledForSession=false、onDisable已调用，放行旧enable及失败disable后仍false；重试旧候选也不解锁。`testVoiceFIFOIsSharedWithAcceptedChatWrites`断言append→voicePreferences→clear的真实顺序与隔离文件，不创建第二个队列。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/VoicePreferencesControllerTests -only-testing:PetMacTests/ChatPersistenceTests`，预期协议/操作缺失或状态断言失败。
- [ ] **Step 3: 实现有序偏好。** Worker复用Task1 store且缓存保护状态，加载missing不写盘。控制器按意图修订/票据处理回执；普通apply先保存，disable立即置本次停用覆盖并停资源再排队保存。只有用户再次明确apply enabled=true且该意图成功才解除临时停用；retry/reset/其他旧回执不能解除。失败保留候选供本地重试/丢弃，保护状态只备份重置voice文件，成功也不开始录音/试听/补读。
- [ ] **Step 4: 验证GREEN。** 同命令；补打开/加载零write、只重试本地、关闭/换角色仍保存全局偏好、旧AI文件摘要不变、重置失败保护及disposed/晚到加载。对照原connection和角色写入测试保持通过；记录待存偏好留给Task6退出汇总接入。
- [ ] **Step 5: 本地提交。** diff与测试通过后提交`feat: persist voice settings through the shared chat queue`。

### Task 5: 共享语音状态、上下文与截止

**Files:** 创建`ChatVoiceController.swift`及`Tests/PetMacTests/ChatVoiceControllerTests.swift`；扩展VoiceFixtures与Xcode登记。

**Interfaces:** 定义`VoiceDraftSnapshot: Equatable`（character: ChatCharacter、revision: UInt64、text: String），`ChatVoiceSurface`（hidden/conversation/settings/other），`VoiceEnvironment: Equatable`（surface: ChatVoiceSurface，其余blocked/effectiveQuiet/sleeping/terminating/disposed为Bool）。`VoiceSavedReply`携带id:UUID/context:ChatCharacter/requestRevision:UInt64/text:String。`@MainActor ChatVoiceController`初始化消费settings:ChatVoicePreferencesController、services:VoiceServices、now:()->Duration、draft:()->VoiceDraftSnapshot?、canRecognize:()->Bool、apply:(VoiceDraftSnapshot,VoiceInsertion)->Bool；提供`beginInput(selection: NSRange)`、`allowNetworkForThisRecording(selection: NSRange)`、`finishInput()`、`cancelInput()`、`acceptPreview()`、`didSaveReply(_ reply: VoiceSavedReply)`、`readLatest(_ text: String)`、`previewVoice()`、`stop()`、`updateEnvironment(_ snapshot: VoiceEnvironment)`、`serviceDeadlines()`、`dispose()`，命令均返回Void。公开只读captureState/preview/error/isSpeaking/blocksChat/suppressesCompletionAudio；权限/停读中也属于blocksChat，suppressesCompletionAudio只覆盖recording/finishing。

- [ ] **Step 1: 写RED。** VoiceFixtures增加独立VoiceControllerHarness，持有临时prefs/FIFO、两个可控服务、草稿修订/插入计数、可前进的now及环境，清理等待所有任务。断言：
  ```swift
  let h = try await VoiceControllerHarness.makeEnabled()
  h.controller.beginInput(selection: NSRange(location: 0, length: 0))
  try await chatEventually { h.input.starts.count == 1 }
  h.advance(by: .seconds(45))
  XCTAssertEqual(h.input.finishCount, 1)
  XCTAssertTrue(h.insertions.isEmpty)
  h.advance(by: .seconds(5))
  XCTAssertFalse(h.controller.blocksChat)
  ```
  `advance(by:)`前进假时钟并调用serviceDeadlines；另断言权限晚回零启动、online选择之前零网络模式、final只插入一次且不发送。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatVoiceControllerTests`，预期新控制器/状态缺失或代次/截止断言失败。
- [ ] **Step 3: 实现单一语音活动。** FrameScheduler只安排本次45秒/5秒的最近截止，空闲无timer；MainActor每次await/Published/外部回调后再检查令牌与完整角色。先确认output.stop成功，再权限/能力/格式检查与start；本机不可用只提供新录音online选项。预览不改draft，final/手动接受使用Task1插入并交apply核对修订；失败/超长不截断或自动接受partial。重开/阻挡/关窗等取消全部令牌和资源，online选择不沿用。
- [ ] **Step 4: 验证GREEN及朗读策略。** 同命令；补草稿ABA/同ID新skinRevision、插入边界、新录音丢旧预览、空/超长和cancel后final。didSaveReply按递增requestRevision先消费、再门控，重复或过旧事件不补读；普通已存回复自动<=600、手动<=8000、中文回退不改保存ID，无音色清晰失败。每次朗读也先await stop确认，失败不开始新输出；录音期间无TTS、stop失败零录音、安静/隐藏/页面/菜单/模态/睡眠/退出停止不恢复，旧语音回调不能清新令牌。同步finish/cancel和Published订阅者同步关窗也须验证。
- [ ] **Step 5: 本地提交。** diff与测试通过后提交`feat: coordinate voice input and read-aloud sessions`。

### Task 6: 聊天草稿、首次保存反馈与退出接入

**Files:** 修改ChatController/ChatController+Lifecycle、ChatFixtures；创建`Tests/PetMacTests/ChatVoiceIntegrationTests.swift`；增补ChatControllerTests/ChatLifecycleTests/MemoryControllerTests及Xcode登记。生命周期接入可拆`ChatController+Voice.swift`，由本任务登记。

**Interfaces:** ChatController新增`private(set) var voice: ChatVoiceController?`，`configureVoice(services: VoiceServices, now: @escaping () -> Duration)`只安装一次，必须向偏好控制器传原writes。提供`voiceDraftSnapshot: VoiceDraftSnapshot?`、`canPrepareVoiceInput: Bool`、`applyVoiceInsertion(_ insertion: VoiceInsertion, expected: VoiceDraftSnapshot) -> Bool`、`takeVoiceSelection() -> NSRange?`及`updateVoiceEnvironment(_:)`。未configure时保持原纯文字测试路径，不自动创建系统服务。草稿修订覆盖setDraft与成功清草稿，voice selection只供实际可见宿主一次性消费。

- [ ] **Step 1: 写RED。** 以ChatControllerFixture和可控voice服务配置，不改原fixture默认行为。`testOnlyFirstSuccessfulModelSaveCanReadAloud`挂起append时spoken=0，释放成功后=1；append失败→本地retry成功后=0且client/key reads不增加。`testVoiceFinalChangesDraftWithoutSendingOrWritingHistory`断言draft插入、client.count=0、历史不变。再钉同ID换肤/草稿ABA、权限中stop/关窗/睡眠/退出和未确认操作零语音确认。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatVoiceIntegrationTests -only-testing:PetMacTests/ChatControllerTests -only-testing:PetMacTests/ChatLifecycleTests -only-testing:PetMacTests/MemoryControllerTests`。
- [ ] **Step 3: 实现有界接入。** canPrepareVoiceInput使用原聊天基础就绪条件但忽略空草稿和语音自身busy，避免录音状态使自己立刻失效；canSend/资料变更/候选确认等另纳入blocksChat。apply核对完整角色、修订、原文和当前生命周期才setDraft并发布插入后选区，takeVoiceSelection也检查当前修订防止陈旧选区。保留Combine订阅转发voice/voice设置变更供两窗原异步render读取，销毁清订阅。外部voice environment缓存后以本controller实际sleeping/terminating/disposed覆盖，每个生命周期入口同步更新，不能等待StatusBar下次refresh才停止。enqueuePair仅原modelReply首次成功反馈路径传VoiceSavedReply，不影响原挥手/气泡onFeedback；retry仍feedback:nil，工具/提炼不走此入口。开始新发送/提炼/清历史、连接关闭、生命周期取消先终止语音，已接受写入不丢。
- [ ] **Step 4: 验证GREEN与退出。** 同命令；将voice hasUnsaved/error纳入terminationSaveError、canRetryTerminationSave、retryAllPendingSaves；等待仍走原FIFO且不遗漏正在接受的偏好。取消退出只恢复可操作状态、不重启录音/朗读；坏voice文件不使纯文字state.failed。验证录音中不能确认记忆/操作、失败预览手动插入后仍要发送、插入结果产生后立刻换窗/换角色不会写入另一角色。
- [ ] **Step 5: 本地提交。** diff与测试通过后提交`feat: integrate voice with chat drafts and saved replies`。

### Task 7: 原生语音控件、第五页与原子交接

**Files:** 创建ChatVoiceControls/ChatVoiceSettingsView和`Tests/PetMacTests/ChatVoiceWindowTests.swift`；修改ChatWindowController、QuickChatWindowController、ChatPresentationCoordinator、ChatPresentationTests及窗口原测试，登记Xcode。

**Interfaces:** `@MainActor ChatVoiceControls: NSStackView`以`init(controller: ChatController, hasBlockingModal: @escaping () -> Bool, hasMarkedInput: @escaping () -> Bool, selection: @escaping () -> NSRange, openSettings: @escaping () -> Void)`建立，`render()`只读取共享状态。`ChatVoiceSettingsView: NSStackView`以`init(controller: ChatController, hasBlockingModal: @escaping () -> Bool, onResetRequested: @escaping () -> Void)`建立，提供render()；reset回调由完整窗呈现原生确认后调用voice设置模型，视图不建服务/队列。ChatPresentationHosting新增`canPresent: Bool`、`voiceSurface: ChatVoiceSurface`，`presentForHandoff(selection: NSRange) -> Bool`；真实宿主及FakeChatHost同步更新。Coordinator公开voiceSurface与`onVoicePresentationChanged: ((ChatVoiceSurface) -> Void)?`，合并交接visibility再通知一次。

- [ ] **Step 1: 写RED。** 新原生测试断言开启前按钮指向设置、录音时结束/取消可达且composer不可编辑、marked text按钮/action均不开始、语音设置不请求权限/发声、五页可达。ChatPresentationTests新增`testRejectedTargetKeepsSourceVisibleAndVoiceRunning`及`testVoiceHandoffNeverPublishesIntermediateHidden`：预检拒绝保留原窗与activeMode，正常full→quick可见性仍[true]且starts/stop计数不变。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatVoiceWindowTests -only-testing:PetMacTests/ChatPresentationTests -only-testing:PetMacTests/ChatWindowTests -only-testing:PetMacTests/QuickChatWindowTests`。
- [ ] **Step 3: 实现UI与交接。** 保留原四页索引，新增index4语音页；连接页由default改明确case3，已有资料编辑规则不变。两窗复用按钮和预览，设置草稿显式应用、关闭语音入口立即调用disable；原停止按钮覆盖模型或语音活动。在线选项为本段非自动模式，有旧预览时以「丢弃预览并重新录音」明确替换。窗口渲染等待Published变更后一个MainActor turn；原输入同步后，仅当前可见宿主消费takeVoiceSelection，handoff优先保留尚未消费的语音选区。目标canPresent检查全局门控/marked/sheet，呈现成功后才隐藏旧窗，失败回滚；交接内抑制中间visibility、最后刷新一次。用户主动离开对话页会取消，handoff内部selectPage(0)/orderOut不作为主动切页或关闭；真正关闭仍调用windowClosed。
- [ ] **Step 4: 验证GREEN与布局。** 同命令；真实setMarkedText、长预览/长错误/online提示/失败重试、320×240与440×420浅深色滚动及可达性；录音/等待final/朗读期间双向交接均不重复服务或改草稿，包含完整窗缓存于非对话页再返回的情况。用户离开对话页取消输入/朗读；语音页可主动试听，其他页不自动读。仅失key或隐藏桌宠不当作聊天隐藏；最小化/App隐藏停止语音但保持原模型隐藏规则。
- [ ] **Step 5: 本地提交。** diff与测试通过后提交`feat: add shared native voice controls and safe window handoff`。

### Task 8: 生产组合、提示音隔离与版本

**Files:** 修改StatusBarController、FocusController、Info.plist、README；创建`Tests/PetMacTests/VoiceProductionIntegrationTests.swift`，扩展FocusCompanionTests及Tests/Distribution/test_distribution.py；登记Xcode。

**Interfaces:** StatusBarController仅生产路径配置`VoiceServices(input: NativeSpeechInput(), output: NativeSpeechOutput())`，并通过`refreshVoiceEnvironment()`组合active surface、menuOpen、双方sheet/NSApp.modalWindow、session.effectiveQuiet及聊天sleeping/terminating/disposed；不覆盖FocusMenus原onChange或PetSession原onStatusChange。FocusController新增`allowsCompletionAudio: () -> Bool = { true }`，只在真正播放提示音处额外判断；原canPlayCompletionSound所有命令用途保持。测试注入服务通过既有chat参数预先configure，生产不能把替身替换成真实服务。

- [ ] **Step 1: 写RED。** `testProductionVoiceIsLazyAndUsesOneSharedOwner`检查构造/开页零权限、零start/voice write/输出，两窗同一voice。`testRecordingSuppressesOnlyCompletionAudio`用真实临时FocusController与播放计数，在录音/finishing时完成仍结算次数/分钟但不响，结束后不补响，原预设/设置门控不被新增音频条件改变。用途声明已在Task2缺失时观察RED；本任务添加实际包回归，不为重复RED撤销声明或以包缺失冒充。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/VoiceProductionIntegrationTests -only-testing:PetMacTests/FocusCompanionTests -only-testing:PetMacTests/QuickChatIntegrationTests`；包用途声明命名为`test_voice_privacy_usage_descriptions`，在Task9最终包回归中运行。
- [ ] **Step 3: 连接生产事件。** 正常菜单打开、模态变化、页面/最小化/App隐藏、安静/专注及生命周期事件刷新语音环境，空闲不加轮询。full内部轻聊入口与quick展开均走预检协调，不再复现0.4同处Minor。focus.allowsCompletionAudio读取voice.suppressesCompletionAudio，原声音偏好与统计不变。Info.plist版本0.5.0/build27，保持14.0和两用途声明；README讲清默认关闭、系统输入/音色准备、45秒、手动发送、在线选择、完整落盘后读与600开头限制。
- [ ] **Step 4: 验证GREEN。** 同原生命令；补打开设置sheet→内部轻聊仍保留旧窗、quiet变更停止输出、chat隐藏/只隐藏桌宠差异、退出等待voice保存失败及重试零服务调用。检查发布验证脚本允许Speech系统依赖，若需调整只针对新系统框架和用途声明，不改CI触发/Release写权限。新的分发断言由Task9干净包验证。
- [ ] **Step 5: 本地提交。** diff与测试通过后提交`feat: wire system voice chat into the desktop app`。

### Task 9: 完整回归、一次整体评审与本地交付

**Files:** 更新docs/system-voice-chat-validation.md、TODO、AGENTS及必要的证据性修复；可控优化探针和原始日志仅放忽略目录`.build/system-voice-chat-validation`，不引入产品探针参数。

- [ ] **Step 1: 执行完整验证并记录真实结果。** `git diff --check`、`bash scripts/test.sh`、`python3 -m unittest discover -s Tests/Release -v`。使用最终同源优化隔离探针、三套真实旧皮肤和假语音服务，覆盖一轮录音草稿→单次模型→保存后读、失败/超时/旧回调、双窗/marked/选区、online选择不重用旧音频、保存失败重试与临时禁用；检查浅深色最小窗PNG。不可仅因程序化事件通过声称真实发声/权限/识别已验收，真实硬件测试留给用户主动操作。
- [ ] **Step 2: 一次最终独立整体代码评审。** 全部分功能完成及原生回归通过后，由一位新的gpt-6-astra/high检查基线至最终功能提交与已批准spec/plan；遵守本会话只一次最终整体评审，不逐任务/另开第二评审。额度/工具中断如实保留，同次评审恢复；Important等问题主执行者先复现再修复并运行相关及完整回归，记录剩余Minor，不能称零已知问题。
- [ ] **Step 3: 从干净来源构建两个架构与包。** 先本地提交最终功能/修复，再顺序执行`bash scripts/build-app.sh`、`bash scripts/build-app.sh x86_64`、`bash scripts/package-app.sh`、`bash scripts/package-app.sh x86_64`、`python3 -m unittest discover -s Tests/Distribution -v`。核对App/build-info的完整SHA、trackedChanges=false、0.5.0/build27、最低14.0、两个隐私用途、ad-hoc签名、系统依赖、原素材摘要、ZIP/DMG库存与SHA256。只把本版八附件复制到独立校验目录，以`python3 scripts/prepare-release.py --assets <该目录> --version 0.5.0 --commit <实际完整SHA> --check-only`完全离线核验；角括号为本步读取的实值，不抄写占位值执行。
- [ ] **Step 4: ARM搬移与个人App更新。** 使用本版ARM DMG，中文空格路径复制后先弹出再运行`python3 scripts/smoke-app.py --app <搬移App绝对路径> --check-restore`，app参数替换为本步复制的真实路径。更新日用前按准确路径正常退出旧0.4.0，备份旧App、退出后主配置与完整AI目录，只比较必要元数据和摘要；装入/Applications、以PID/路径/版本/库存/自有窗口确认运行，原偏好/皮肤/位置与AI已有文件保留，缺失voice文件启动不创建。此步骤不申请真实录音授权或自动试听，不改正式登录项/钥匙串。
- [ ] **Step 5: 完成本地交付记录并请用户体验。** 分别列出自动测试、隔离探针、双架构包与ARM搬移/安装结果，以及实际声音、输入设备/权限、zh-CN本机/允许联网、真实DeepSeek、物理输入/睡眠/Spaces/Gatekeeper/本版Intel和云端编译等未测项。交付本地App与安装包链接，用户在App中启用语音并主动体验；有实际失败再据证据修复，不提前记通过。不push/tag/Release。完成账本只归档本计划到忽略证据目录，不恢复或清理其他计划。

## 执行说明与自审

每项任务按RED→最小实现→GREEN→本地提交执行；引擎权限/设备等环境失败独立记账，不能当需求RED。异步断言等真实可控事件并设超时，不用固定yield次数或随意sleep证明成功；原全套回归在最终阶段运行，除新改动/失败/疑点不重复已通过的无变化检查。

主执行者应按spec逐项自审此计划：输入/权限/选区在Tasks1/2/5/6，输出/完整落盘在Tasks3/5/6，偏好/退出在Tasks1/4/6，双窗/模态在Tasks7/8，原声音门控在Task8，证据与交付在Task9。所有跨任务类型和方法以各Interfaces为准；若实施中必须调整公开接口，同步更新所有使用处、测试与账本，不放宽数据流/确认/取消合同。计划自审由主执行者完成，不另派计划评审者；只读测试位置调查不算计划/代码评审。

主执行者已完成spec覆盖、步骤粒度、接口类型、五项Review Focus和篇幅比例自审，并补清停止确认后才输出、偏好dispose、父控制器即时生命周期同步、handoff内部切页和只影响提示音的独立门控。计划与设计长度相近，不复制产品实现体；本阶段未执行产品测试、代码评审或构建。

当前请用户审核本计划；用户已选本会话Native原地执行，不重问方式。计划获准才实施，不能把设计批准当作实施计划已批准。
