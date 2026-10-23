# DeepSeek 角色文字聊天 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为现有单角色桌宠增加可设定人设、流式回复、按角色保留最近 12 轮并可重开续聊的 DeepSeek 文字聊天。

**Architecture:** PetCore 承担会话模型和受限存档，Mac 侧通过原生 URLSession 与钥匙串适配外部服务。MainActor 聊天控制器分开管理网络请求代次与已接受的文件事务，独立 AppKit 窗口由状态栏控制器持有。现有动画调度、主配置 schema13 与专注计时保留原合同。

**Tech Stack:** Swift 6、AppKit、Foundation URLSession、Security、CryptoKit、XCTest；macOS14+，无新增依赖。

**Spec:** [已批准的书面设计](../specs/2026-10-23-macos-deepseek-chat-design.md)。

**执行方式:** 保留用户此前明确选择的 Native：本会话由主执行者依次实施、按任务自测提交，最后安排一次独立整体代码评审。辅助代理仅作只读事实核对，不按任务另开实现/评审会话，不额外建工作树。

**状态:** 用户已认可书面设计并要求进入实施计划；用户已于2026-10-23明确批准本计划并要求按本会话方式实施，现按任务执行。仓库 `/Users/resker/develop/github/YeShunguangPet-macOS`；分支 `codex/macos-deepseek-chat`；产品基线 `7e87dd5`，设计提交 `3f37718`。相对路径均从仓库根起算。

## Global Constraints

- 交付目标为 0.1.22 / build23。
- 保持 Swift 6、macOS14+、系统框架与现有 XCTest。
- arm64 本地可体验，x86_64 保留交叉构建与分发核验。
- 现有 schema13、真实旧皮肤、专注规则和全部持久偏好保持原有合同；聊天资料单独保存。
- 按清单 `manifest.id` 保存人设与最近 12 轮完整对话。
- 默认 `deepseek-flash` 非思考模式；用户可改选 `deepseek-v4-pro`。
- 请求只含人设、最近完整对话和本次文字；仅在用户发送时联网。
- 密钥使用 macOS 钥匙串，不进入 JSON、皮肤、Git、日志或诊断；自动化默认注入内存替身。
- 沿用独立 Mac 仓库原地开发，不另建工作树；Windows 与 Minimal Sleep 仅作只读参考。
- 推送、标签和 Release 继续需要新的明确指令。

## Review Focus

1. 中文输入法尚未提交、emoji/组合字素恰好位于长度边缘：不能误发或切坏摘录；Task 1 / 6 分别固定文本与原生输入行为。
2. 12 轮中文长对话合法超过现有 StrictJSON 的 128 KiB：存档须能读取，旧皮肤默认上限仍为 128 KiB；Task 2 固定两条合同。
3. 旧请求已完成并登记落盘后换肤、再清空；清空失败或成功都不能使旧结果串角色/复活：Task 4 / 5 用可控事务顺序直接证明。
4. 睡眠或退出取消发生在凭据读取/流接收期间，通知来自后台，随后取消退出：不能触发 Swift6 actor 断言、继续旧请求或自动重发；Task 5 / 6 固定入口与结果。
5. 钥匙串拒绝/用户取消，或密钥成功而偏好保存失败：界面必须反映实际状态，不发未授权请求、不把部分成功显示为全部成功；Task 3 / 5 验证。

---

## 文件与接口地图

| 文件 | 单一职责 |
| --- | --- |
| `Sources/PetCore/Chat/ChatModels.swift` | 模型选择、连接偏好、角色人设、消息、完整会话与请求快照 |
| `Sources/PetCore/Chat/ChatText.swift` | UTF-16/控制字符校验、保持字素的短摘录 |
| `Sources/PetCore/Chat/ChatStore.swift` | 角色 v1 档案及坏文件保护 |
| `Sources/PetCore/Chat/ChatConnectionStore.swift` | 连接 v1 偏好及保护 |
| `Sources/PetCore/Chat/ChatAtomicFile.swift` | 受限权限的同目录原子写入与备份 |
| `Sources/YeShunguangPet/Chat/ChatSSEDecoder.swift` | 有界 SSE、完成合同与文字事件 |
| `Sources/YeShunguangPet/Chat/DeepSeekChatClient.swift` | 官方固定来源、请求、取消及 HTTP 错误 |
| `Sources/YeShunguangPet/Chat/ChatCredentialStore.swift` | 钥匙串接口与适配 |
| `Sources/YeShunguangPet/Chat/ChatPersistence.swift` | 后台文件工作者与已接受事务 FIFO |
| `Sources/YeShunguangPet/Chat/ChatController.swift` | 当前角色/请求/草稿/未保存完整问答 |
| `Sources/YeShunguangPet/Chat/ChatController+Lifecycle.swift` | 睡眠、关窗与可测试退出协调 |
| `Sources/YeShunguangPet/Chat/ChatWindowController.swift` | 原生窗口及三页呈现 |
| `Sources/YeShunguangPet/Chat/ChatComposer.swift` | 原生多行输入与中文组合输入处理 |
| `Sources/YeShunguangPet/PetSession.swift` | 小型聊天暂停/反馈入口及成功换肤版本 |
| `Tests/Support/ChatFixtures.swift` | 内存凭据、可控流、可控存储、临时角色夹具，仅测试 |

Xcode 工程使用 XML plist 显式登记，没有目录自动同步或生成器。每个任务登记自己新增的文件：纯模型/存储进入 PetCore；Core 用例进入 PetCoreTests；Mac 适配生产源码同时进入 App 和 PetMacTests，后者直接编译适配源码、没有 TEST_HOST。共享测试夹具只进入需要它的测试 target。修改 `YeShunguangPet.xcodeproj/project.pbxproj` 后检查 Sources phase，验证日志必须出现新用例，不能把“零用例成功”当通过。

跨 PetCore 使用的上述类型及下列接口设为 public；值模型采用 Codable/Equatable/Sendable，运行中请求快照采用 Equatable/Sendable，不把密钥或控制器编码。Mac 适配保持 internal。不同文件的控制器扩展通过受控内部方法共享生命周期状态，不依赖跨文件访问 private 成员。

## Task 1：会话模型、提示词与文本边界

**Files:** 创建地图中 `ChatModels.swift` / `ChatText.swift`；创建 `Tests/PetCoreTests/ChatConversationTests.swift`；登记工程。

**Interfaces:**
- `ChatModel: String, Codable, CaseIterable, Sendable`，`flash = "deepseek-flash"`、`pro = "deepseek-v4-pro"`。
- `ChatConnection(enabled: Bool = false, model: ChatModel = .flash)`、`ChatProfile(background: String = "", personality: String = "", speakingStyle: String = "", examples: String = "")` 为 Codable/Equatable/Sendable；`ChatProfile.validate() throws`。
- `ChatMessage(role: ChatMessage.Role, content: String)` 为 Codable/Equatable/Sendable，Role 为 String/Codable/Sendable 的 system/user/assistant；`ChatConversation(characterID: String, profile: ChatProfile = .init(), messages: [ChatMessage] = []) throws` 同样为 Codable/Equatable/Sendable；`func appending(user: String, assistant: String) throws -> ChatConversation`。
- `ChatPromptSnapshot(characterID: String, characterName: String, conversation: ChatConversation, model: ChatModel, input: String) throws`，产生只读 `characterID/model/messages`，校验角色一致后冻结 system/完整历史/current user。
- `ChatText.validate(_ text: String, maxUTF16: Int, allowEmpty: Bool) throws`、`ChatText.excerpt(_ text: String, limit: Int = 80) -> String`；统一受控的本地错误文案，不拼接服务端原文。

- [x] **1. 写失败用例。** `testThirteenPairsRetainsNewestTwelve` 的核心断言：
```swift
var state = try ChatConversation(characterID: "ye-shunguang")
for i in 1...13 { state = try state.appending(user: "u\(i)", assistant: "a\(i)") }
XCTAssertEqual(state.messages.count, 24)
XCTAssertEqual(state.messages.first?.content, "u2")
XCTAssertEqual(state.messages.last?.content, "a13")
```
  加入 `testUTF16AndWholeGraphemeLimits`：1000 个普通 emoji 用户输入可用、1001 个拒绝；回复 8000 单元可用、8001 拒绝；80 单元摘录不切断家庭组合 emoji。`testProfileAndPromptContract` 断言四项上限 2000/1000/1000/2000、允许空人设/普通换行、拒绝 NUL/空输入/错角色/奇数或错误角色序列，提示只含人设、历史与当前输入。
- [x] **2. 运行 RED。** `bash scripts/test.sh -only-testing:PetCoreTests/ChatConversationTests`；确认缺少新行为/类型导致失败，而非测试未登记。
- [x] **3. 实现上述模型和函数。** 角色 ID 使用清单的小写 ID 合同，档案不允许 system 消息；以整轮截断，当前草稿不加入会话；摘录包含省略号也不超过 80 UTF-16 单元。
- [x] **4. 运行同一命令验证 GREEN。** 日志列出该类全部实际用例且零失败。
- [x] **5. 提交。** `git add Sources/PetCore/Chat/ChatModels.swift Sources/PetCore/Chat/ChatText.swift Tests/PetCoreTests/ChatConversationTests.swift YeShunguangPet.xcodeproj/project.pbxproj`；`git commit -m "feat: model bounded character conversations and persona prompts"`。

## Task 2：独立档案、保护与原子保存

**Files:** 创建地图中三个 Core 存储文件和 `Tests/PetCoreTests/ChatStoreTests.swift`；修改 `Sources/PetCore/Skin/StrictJSON.swift` / `Tests/PetCoreTests/StrictJSONTests.swift`；登记工程。

**Interfaces:**
- `ChatLoadResult<Value: Sendable>: Sendable`：missing / loaded(Value) / protectedFile(String)。
- `ChatStore.init(directory: URL, write: ((Data, URL) throws -> Void)? = nil, backup: ((URL, URL) throws -> Void)? = nil)`；`load(characterID: String) -> ChatLoadResult<ChatConversation>`、`save(_ value: ChatConversation) throws`、`backupAndReset(characterID: String, profile: ChatProfile) throws -> ChatConversation`。
- `ChatConnectionStore.init(url: URL, write: ((Data, URL) throws -> Void)? = nil, backup: ((URL, URL) throws -> Void)? = nil)`；`load() -> ChatLoadResult<ChatConnection>`、`save(_ value: ChatConnection) throws`、`backupAndReset() throws -> ChatConnection`。
- `ChatAtomicFile.write(_ data: Data, to url: URL) throws` 为存储内部实现，创建 0700 目录和 0600 临时文件，写入后同目录 rename；权限在提交前建立，不在 rename 成功后再抛出伪造的“未提交”错误。
- 新增 `StrictJSON.validate(_ data: Data, maximumBytes: Int) throws`；既有 `validate(_:)` 及 `parse(_:)` 的默认 131072 字节和错误行为保持，内部复用同一个解析器、深度仍 64；仅聊天角色档案显式使用 2097152 字节。

- [x] **1. 写失败用例。** `testArchivesReopenAndPreserveMainSettings` 验证 v1、SHA-256 文件名、同 ID 共用/异 ID 隔离，重建 store 后 24 条记录一致，`settings.json` 原字节相等。`testLargeChineseArchiveRetainsSkinLimit` 构造 12 轮各 2000/8000 中文单元，断言序列化 >131072 且可保存重读；同一数据经默认 StrictJSON 必须拒绝。
- [x] **2. 补保护和写失败断言。** `testProtectedArchivesNeverOverwrite` 覆盖重复键、未知版本、错 ID、非法轮次、连接 >8192/角色 >2097152；原字节保持。`testAtomicWriteAndResetFailures` 注入 write/backup 失败，旧文件和保护状态保持，成功重置才解除；权限核对 0700/0600，无临时残留，失败错误不含聊天正文。
- [x] **3. 运行 RED。** `bash scripts/test.sh -only-testing:PetCoreTests/ChatStoreTests -only-testing:PetCoreTests/StrictJSONTests`，核对真实失败。
- [x] **4. 实现存储。** 角色封装为 `{schemaVersion: 1, conversation: ...}`；连接为 `{schemaVersion: 1, connection: ...}`。不因 missing 立即写文件；连接只存 enabled/model。先按各自上限验证字节和严格 JSON，再解码；坏文件只经确认备份重置。
- [x] **5. 运行同一命令 GREEN。** 连同默认皮肤/manifest 相关原生用例验证原 128 KiB 合同未放宽。
- [x] **6. 提交。** 精确暂存本任务文件与工程；`git commit -m "feat: persist isolated chat archives with protected atomic writes"`。

## Task 3：DeepSeek 流式接口与钥匙串

**Files:** 创建地图中 `ChatSSEDecoder.swift` / `DeepSeekChatClient.swift` / `ChatCredentialStore.swift`；创建 `Tests/PetMacTests/ChatClientTests.swift` / `ChatCredentialTests.swift` 及地图测试夹具的网络/凭据部分；登记工程。

**Interfaces:**
- `ChatStreamEvent: Equatable, Sendable`：delta(String) / completed；`ChatSSEDecoder.append(_ data: Data) throws -> [ChatStreamEvent]`、`finish() throws`。
- `protocol ChatStreaming: Sendable`：`stream(_ snapshot: ChatPromptSnapshot, apiKey: String) -> AsyncThrowingStream<ChatStreamEvent, Error>`。
- `DeepSeekChatClient.init(configuration: URLSessionConfiguration = DeepSeekChatClient.configuration())`；`static configuration() -> URLSessionConfiguration`；实现 ChatStreaming，stream 终止会取消底层 Task/session。
- `protocol ChatCredentialStoring: Sendable`：`read() async throws -> String?`、`save(_ secret: String) async throws`、`remove() async throws`。
- `actor KeychainChatCredentialStore` 实现协议，`init(service: String = "io.github.resker666.yeshunguangpet.macos.deepseek", account: String = "api.deepseek.com")`；错误映射只含固定类别/OSStatus。测试以内存实现为默认，禁止用上述正式标识做试验。

- [x] **1. 写网络失败用例。** `testOfficialRequestContract` 断言精确 URL/POST/Bearer 测试凭据、无 Cookie、stream true、thinking disabled、max_tokens 2048、无 tools/图片、仅冻结消息；配置为 30/120 秒、无 cache/cookie。
- [x] **2. 写流和取消失败用例。** `testSSEAllByteBoundariesAndCompletion` 把包含中文/emoji/CRLF/keep-alive/空 choices 的合法 SSE 在每个字节位置切开，合并文本相同且只有一次 completed。`testSSERejectsTruncationAndLimits` 对无 DONE、无 stop、错误结束、非法 JSON/UTF-8、空回复、>8000 单元、单行/单事件 >65536 字节或总响应 >1048576 字节断言抛错。`testCancellationAndHTTPFailuresNeverRetry` 覆盖停止后 stopLoading、晚到分段、401/402/429/400/422/500/503、302、错误来源、超时/断网，网络请求计数保持 1。
- [x] **3. 写凭据失败用例。** `testCredentialFailureMappingAndNoFileStorage` 验证用户取消/拒绝/缺失映射、保存/删除结果独立，无普通文件；key 为空/含控制字符/超过 4096 UTF-8 字节拒绝。
- [x] **4. 运行 RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatClientTests -only-testing:PetMacTests/ChatCredentialTests`，确认新客户端/凭据行为尚未实现的失败。
- [x] **5. 实现客户端和解码器。** 先复核设计链接的官方模型/接口文档，不用用户密钥发请求；固定官方源、拒绝重定向。增量处理 data，忽略 reasoning/保活，只有 stop + DONE + 非空才 completed，不自动 fallback 再请求。对请求 1 MiB、响应 1 MiB、每行/事件 64 KiB 分别限制；原始错误体不进日志。流只通过 Sendable 事件跨线程。
- [x] **6. 实现凭据适配。** SecItem 通用密码读/替换/移除在 actor 内，密钥输入只修剪首尾空白；不启动时读 key，不回显已存值。真实随机命名钥匙串探针另记人工/隔离证据，失败不以替身结果替代。
- [x] **7. 运行 GREEN。** 同 RED 命令，核对本任务新增的两类实际用例均执行且零失败。
- [x] **8. 提交。** 精确暂存本任务生产/测试/工程文件；`git commit -m "feat: connect bounded DeepSeek streams and Keychain credentials"`。

## Task 4：有序文件事务与跨角色待存结果

**Files:** 创建 `ChatPersistence.swift`、`Tests/PetMacTests/ChatPersistenceTests.swift`；扩展 `Tests/Support/ChatFixtures.swift`；登记工程。

**Interfaces:**
- `ChatWriteOperation: Sendable`：profile(characterID:String, profile:ChatProfile)、append(characterID:String, user:String, assistant:String)、clear(characterID:String)、reset(characterID:String, profile:ChatProfile)、connection(ChatConnection)、resetConnection。
- `ChatStoredValue: Sendable`：character(ChatConversation) / connection(ChatConnection)；`ChatWriteTicket: Equatable, Sendable` 含单调 `sequence: UInt64`。
- `protocol ChatPersisting: Sendable`：`loadCharacter(id: String, defaultProfile: ChatProfile) async -> ChatLoadResult<ChatConversation>`、`loadConnection() async -> ChatLoadResult<ChatConnection>`、`apply(_ operation: ChatWriteOperation) async throws -> ChatStoredValue`。
- `actor ChatArchiveWorker` 用 Task 2 stores 实现上述协议；`init(settingsURL: URL)`，根为其父目录/AI。维护最新有效角色值，变更不能直接覆盖过期快照。
- `@MainActor final class ChatWriteQueue`：`init(persistence: any ChatPersisting)`；`enqueue(_ operation: ChatWriteOperation, completion: @escaping @MainActor (ChatWriteTicket, Result<ChatStoredValue, Error>) -> Void) -> ChatWriteTicket`；`hasPending: Bool`、`waitForPending() async`。登记同步发生，单一 runner 逐个 await apply，禁止靠 Task 调度先后猜测 FIFO；队列不随网络取消撤销。

- [x] **1. 写失败用例。** `testAcceptedAppendThenClearRemainsEmpty` 用可控 worker 挂起 append，enqueue clear，依次释放并断言调用顺序为 append/clear，最终消息数 0。`testClearFailurePreservesCommittedState` 分别让前一 append 成功/失败，断言有效旧历史及需重试完整问答的归属不会丢失。
- [x] **2. 写取消独立断言。** `testAcceptedMutationSurvivesRequestCancellation` 确认 ticket 登记后调用方取消不撤销 write，receipt 仍指向旧角色；`testQueueDrainsBeforeExit` 断言 drain 挂起直到全部已接受事务完成。
- [x] **3. 运行 RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatPersistenceTests`，确认新事务行为的失败。
- [x] **4. 实现 FIFO。** worker 在后台读写；profile/append/clear/reset 都针对最新有效值执行，save 成功才推进有效值，失败保留旧值。主线程 receipt 序号控制界面发布，网络 generation 不参与撤销文件事务。
- [x] **5. 同命令 GREEN。** 夹具直接控制 continuation，不用 sleep 碰时序；确认每个事务完成一次，工作不落到 MainActor 同步文件 I/O。
- [x] **6. 提交。** 精确暂存本任务文件；`git commit -m "feat: serialize accepted chat mutations across lifecycle changes"`。

## Task 5：聊天控制器、请求代次与退出协调

**Files:** 创建 `ChatController.swift` / `ChatController+Lifecycle.swift`、`Tests/PetMacTests/ChatControllerTests.swift` / `ChatLifecycleTests.swift`；补齐共享夹具；登记工程。

**Interfaces:**
- `ChatCharacter: Equatable, Sendable` 包含 `id/name/description: String` 与 `skinRevision: UInt64`；版本只表示成功换肤。
- `@MainActor final class ChatController: ObservableObject`，`init(persistence: any ChatPersisting, credentials: any ChatCredentialStoring, client: any ChatStreaming, canDispatch: @escaping () -> Bool, onFeedback: @escaping (String) -> Void)`。
- 命令为 `activate(_ character: ChatCharacter)`、`setDraft(_ text: String)`、`send()`、`stop()`、`applyProfile(_ profile: ChatProfile)`、`saveConnection(_ value: ChatConnection)`、`saveCredential(_ secret: String)`、`removeCredential()`、`clearHistory()`、`retryPendingSave()`、`discardPendingSave()`、`resetCharacterArchive()`、`resetConnectionArchive()`，返回 Void，异步工作由 controller 持有；命令在入口检查可用性。
- 发布 `character/conversation/draft/partialReply/state/connection/error/canSend/hasPendingWrites/unsavedCharacterIDs`；state 明确 idle/loading/readingCredential/streaming/saving/unsaved/failed，切角色读取也使用代次挡晚到。
- 生命周期：`setPresented(_ presented: Bool)`、`windowClosed()`、`setSleeping(_ sleeping: Bool)`、`beginTermination()`、`cancelTermination()`、`waitForPendingWrites() async`、`retryAllPendingSaves() async -> Bool`、`dispose()`。setPresented 仅记录实际呈现，最小化/App 隐藏不等于关闭；windowClosed 才取消生成并丢弃未应用人设编辑。只读 key 由显式 send 发起；初始凭据状态未知，第一次发送先检查，缺失时不发 HTTP 并提示连接页。
- `ChatController+Lifecycle` 单独监听 NSWorkspace 睡眠/屏幕睡眠；selector 非隔离并安全转 MainActor，dispose 后忽略。不能依赖 PetSession.setSleeping 的状态栏回调，它目前不会发 onStatusChange。

- [ ] **1. 写请求和角色失败用例。** `testManualSingleFlightAndTwelveRoundReopen` 断言启动/activate/改连接不调用 read/网络，重复 send 仅 1 次；完成后可经新 controller 读取。`testRoleSwitchRejectsStaleStreamAndLoad` 先挂起 A 的加载/流，切 B 后完成 A，B 窗口/历史不变；同 ID 新 skinRevision 也停止旧请求，档案仍共用。
- [ ] **2. 写保存失败断言。** `testPendingPairSurvivesSwitchAndLocalRetryDoesNotRequestAgain`：失败完整问答归 A，B 可用，切回 A 可恢复，重试只增加 write 不增加 read/HTTP；A 禁止下一条和人设应用。`testClearAfterAcceptedAppendCannotResurrectHistory` 覆盖 Task 4 顺序在 controller 的窗口/缓存表现。
- [ ] **3. 写生命周期与部分成功断言。** `testBackgroundSleepAndCancelledTerminationNeverResumeRequest` 在凭据读取和流阶段发后台睡眠通知，断言无 actor 崩溃、旧结果不落盘、取消退出/唤醒不重发。`testCloseAndExitPreserveAllPendingRoles` 覆盖关窗后待存、退出等待全部角色。`testCredentialAndPreferencePartialResultsAreReported`：key 成功/偏好失败不冒充全成功，拒绝/取消 key 不发 HTTP；仅 AI 关闭可在生成中立即应用。
- [ ] **4. 运行 RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatControllerTests -only-testing:PetMacTests/ChatLifecycleTests`，核对相应新行为的失败。
- [ ] **5. 实现控制器。** 以角色 ID 缓存 draft/pending；请求冻结全部输入，正常结束且代次有效后同步登记 append ticket。ticket 的完成始终更新所属角色；只有当前角色、有效请求且首次保存成功才调用 onFeedback，本地重试不调用。流文本最多约 50ms 合并发布，取消/结束立即更新，不增加常驻轮询。
- [ ] **6. 实现退出边界。** beginTermination 立即取消网络，wait 只等文件，不重新请求；retryAllPendingSaves 返回实际总结果。模态/退出门控覆盖所有保存、清空与重置命令，退出专用本地重试走受控路径；三类编辑草稿按设计保留或丢弃。
- [ ] **7. 运行同命令 GREEN。** 确认角色、存储、请求和生命周期各具名用例实际执行并零失败。
- [ ] **8. 提交。** 精确暂存本任务文件；`git commit -m "feat: manage character chat cancellation and recoverable saves"`。

## Task 6：独立 AppKit 窗口、菜单与桌宠接入

**Files:** 创建地图中 `ChatWindowController.swift` / `ChatComposer.swift`、`Tests/PetMacTests/ChatWindowTests.swift` / `ChatIntegrationTests.swift`；修改 `Sources/YeShunguangPet/StatusBarController.swift`、`Sources/YeShunguangPet/AppDelegate.swift`、`Sources/YeShunguangPet/PetSession.swift`、`Sources/YeShunguangPet/Info.plist`、`Sources/YeShunguangPet/Settings/HelpSettingsView.swift` 及工程；不增加主设置 Tab。

**Interfaces:**
- `ChatComposer: NSTextView`，`var onSend: (() -> Void)?`；Enter 换行，Command+Enter 仅在 `hasMarkedText() == false` 时发送。
- `@MainActor final class ChatWindowController: NSWindowController, NSWindowDelegate`：`init(controller: ChatController, onPresentationChange: @escaping (Bool) -> Void)`、`present()`、`beginTermination()`、`cancelTermination()`、`dispose()`；接入独立对话/人设/连接三页。
- PetSession 增加 `private(set) var skinRevision: UInt64`，仅 switchSkin 成功提交并替换后增加；`setChatPresented(_ presented: Bool)`、`presentChatReply(_ text: String)`，返回 Void。反馈方法留在 PetSession.swift 内以访问现有私有气泡/调度；不作无关大拆分。
- StatusBarController 长期持有 `chat/chatWindow`，refresh 只在角色快照变化时 activate，不能每秒重载；现有单份 onStatusChange 继续由它持有。可测协调放 controller，AppDelegate 只衔接 NSApplication reply/alert。

- [ ] **1. 写输入/布局失败用例。** `testCommandEnterHonorsMarkedText` 使用已组合/未组合输入夹具断言发送次数 0/1、普通 Enter 换行；`testWindowLayoutAndPlainText` 检查 520×620/最小 440×420、三页可达/滚动、浅深色、纯文本复制与长回复，后台到达不调用激活。程序化 IME 断言不记作真实输入法验收。
- [ ] **2. 写集成失败用例。** `testTwoChatEntriesShareOneController` 断言菜单栏和右键打开同一会话、父子菜单/模态/退出门控正常、主设置仍七 Tab。`testChatAndSettingsPauseSourcesAreIndependent` 验证各自开关/最小化/App 隐藏互不释放另一暂停来源；手动输入及 focusQuiet 保留。`testReplyFeedbackHonorsAllGates` 覆盖可见/睡眠/安静/专注/菜单/设置/鼠标/手动动作，台词开关、80 单元、失败/重试/关窗/换肤不补播，缺失 waving 回 idle。
- [ ] **3. 运行 RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatWindowTests -only-testing:PetMacTests/ChatIntegrationTests`；新用例必须实际执行。
- [ ] **4. 实现窗口与菜单。** 标题随角色，档案受保护/未保存状态有明确操作；人设离页丢弃未应用编辑，聊天 draft 本次运行保留。总开关和模型、钥匙串写入分别反馈，密钥草稿保存成功清空；明确清空/重置确认并复用模态门控。打开才激活、关窗取消生成；原角色单双击不改。Info.plist 设置 0.1.22/build23，最低系统仍 14.0；帮助增加聊天配置、发送范围和记录清除的简短操作说明。
- [ ] **5. 实现所有权、暂停与退出。** status 创建早于 session.start，聊天不得抢先存默认资料。成功换肤版本通知经过已有 refresh 转发；chatPresented 加入被动行为条件，普通互动台词暂停，独立短摘录沿用 6 秒期限。AppDelegate 同时等待皮肤与聊天已接受变更；未保存问答允许本地重试/继续退出/取消，取消退出不重发，不破坏原皮肤清理与主配置失败决策。
- [ ] **6. 运行 GREEN。** 运行上述用例及既有 ContextMenuTests/SettingsGroupsTests/FocusCompanionTests/SpeechSessionTests，核对零失败。
- [ ] **7. 提交。** 精确暂存本任务文件；`git commit -m "feat: add native character chat window and desktop integration"`。

## Task 7：完整回归、独立评审与本地 App 交付

**Files:** 创建 `docs/deepseek-chat-validation.md`；更新 `README.md` / `TODO.md` / `AGENTS.md` 和本计划复选框；如需把包内排除聊天资料作为回归，修改 `Tests/Distribution/test_distribution.py`，不写仅检查实现字符串的用例。隔离探针/截图/日志放忽略目录 `.build/deepseek-chat-validation`。

- [ ] **1. 完整验证。** `bash scripts/test.sh`；`python3 -m unittest discover -s Tests/Release -v`。报告实际原生数量和 13 项离线发版结果；新失败先定位，不预填通过数字。复核官方当前模型/API 合同，只查文档，不用任何日用密钥发请求。
- [ ] **2. 隔离原生探针。** 用临时 YSGPET_SETTINGS_PATH、假凭据及可控流跑三套旧皮肤/12 轮重开/坏档案/晚到流/保存失败/清空/双窗口/退出；优化 Bundle 验证窗口与气泡可见和资源关闭，截图用原生缓存或可用 UI 工具并准确注明。真实 SecItem 仅随机测试 namespace，若不可用留未测；不触碰正式凭据或登录项。
- [ ] **3. 单次独立整体代码评审。** 审核 `7e87dd5..当前实现提交` 的设计覆盖、线程、状态、文件与网络边界。Important/Critical 先复现再修复、跑相关与必要完整回归；不自动派第二次独立整体评审。修复/验证记录与交付说明先本地提交，随后用于干净构建。
- [ ] **4. 干净双架构构建和打包。** 确认 git status 干净，顺序运行：
```bash
bash scripts/build-app.sh arm64
bash scripts/build-app.sh x86_64
bash scripts/package-app.sh arm64
bash scripts/package-app.sh x86_64
python3 -m unittest discover -s Tests/Distribution -v
```
  核对干净来源 SHA、0.1.22/build23、架构/最低14.0/签名/原素材/依赖/库存/八文件摘要；包不含 AI 个人档案或凭据。用 `scripts/prepare-release.py --help` 核对现有参数，再按现有 `--check-only` 路径离线核验八附件，不触发远端草稿。
- [ ] **5. ARM 离工程重开。** 从最终 DMG 复制到真正包含中文与空格的临时路径，弹出 DMG 后 `python3 scripts/smoke-app.py --app <实际绝对路径> --check-restore`，配置和素材均隔离；核对 App/DMG/ZIP 库存一致。失败保留日志，未查清不能记已修复；Intel 交叉构建不记作运行通过。
- [ ] **6. 本机安装。** 按准确路径正常退出旧 App，保留旧 App 与退出后配置备份；安装最终干净 ARM App 到 /Applications 并启动。对比 schema13 的全部既有字段、素材选择与位置；本次 AI 默认关闭，不登记登录项或读取/填写密钥。证据不输出个人字段原文。
- [ ] **7. 交付与验收入口。** 记录来源 SHA、真实通过/失败/未测项与回滚备份位置，提交文档收尾。用户在 App 的连接页自行填写 DeepSeek 密钥并发送，检查流式回复、停止、换角色与重开；没有该实际操作就写“真实 DeepSeek 往返未测”。中文输入法、物理交互/焦点、实际钥匙串提示、系统睡眠/Spaces/多屏/Gatekeeper/本版 Intel 仍按观察范围记录，不推送或发布。

## 计划自审记录

- 覆盖：设计 1–4 节由 Task 1/5/6 落实；5 节由 Task 2/3/4；6 节由 Task 3/5；7 节由 Task 4/5/6；8 节对应文件地图；9 节由各任务 RED/GREEN 与 Task 7 交付覆盖。
- 接口：Task 1 先定义不可变 Sendable 值，Task 2 同步 store 仅由 Task 4 后台 worker 持有；Task 5 消费统一 ChatPersisting/ChatStreaming/ChatCredentialStoring，Task 6 不另建第二份会话或替换已有回调。
- 比例：七个可独立验证的交付任务；工程登记/夹具跟随各自任务，未拆出无产物的 setup 任务，也未预写实现函数体。
- Review Focus 五项均映射到具名用例；StrictJSON 现有上限、逻辑测试重复编译 App 源码、无状态回调的睡眠与主循环初始化顺序已明确处理。
- 本文已获用户审核；复选框按实际执行更新，测试/构建/真实服务或新 App 状态以日志为准。保留 Native、本会话执行与单次独立最终评审方式。
