# 角色长期记忆 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为现有角色聊天增加由模型提炼、用户确认、按角色持久保存并可编辑删除的长期记忆。

**Architecture:** PetCore 承担有界记忆、提炼快照/严格候选解码以及 v1→v2 档案读取。Mac 侧复用官方 DeepSeek 流式传输，以一个请求门控协调普通聊天和提炼，以既有 FIFO 协调已确认记忆变更和其他角色资料写入。原生聊天窗增加记忆页，候选草稿与确认后保存失败的意图具有不同寿命。

**Tech Stack:** Swift 6、AppKit、Foundation URLSession、现有 Security/CryptoKit/XCTest；macOS14+，无新增依赖。

**Spec:** [已批准的书面设计](../specs/2026-10-23-macos-character-memory-design.md)，用户于2026-10-23明确认可并要求进入实施计划。

**执行方式:** 保留已选 Native：主执行者在本会话原地逐任务实施、自测和本地提交，最后一次独立整体代码评审；辅助代理仅作只读事实核对。不额外创建工作树、不逐任务派实现/评审代理，也不重新要求用户选择执行方式。

**状态:** 用户于2026-10-23明确认可计划并要求按本会话方式实施；现按七项任务连续执行。仓库 `/Users/resker/develop/github/YeShunguangPet-macOS`，本地分支 `codex/macos-character-memory`；产品基线 `2c15595`，设计初稿提交 `46e2b9e`。下列相对路径从仓库根起算。

## Global Constraints

- 交付版本为 **0.3.0 / build25**；保持 Swift 6、AppKit、macOS14+、系统框架和现有 Xcode。
- 每次用户点击「提炼记忆」才发起额外请求，从当前角色已经保存的最近 12 轮完整对话产生至多 5 条候选。
- 候选初始不勾选，用户查看来源、编辑、选择并明确保存；未经确认不写档案、不进普通聊天上下文。
- 每个 `manifest.id` 最多保存 20 条、每条最多 200 个 UTF-16 单元的记忆；不同 ID 隔离，同 ID 皮肤副本共用。
- 正文 Unicode NFC 后去除首尾空白；拒绝非法控制字符、空值、重复 UUID 及规范化后完全相同的正文；不自动语义合并、替换或淘汰。
- 原有 v1 聊天档案无损读取为「记忆为空」，后续明确保存时写入 v2；主配置保持 schema13。
- 清空普通历史保留人设和记忆；清除记忆保留人设和历史；备份并重置清除整份角色资料。
- App 内任一时刻最多一个 AI 请求，使用当前官方 DeepSeek 模型与既有钥匙串项；普通聊天和提炼均无自动重试/备用请求。
- 1 MiB 请求/总响应、30 秒请求闲置、120 秒总时限、64 KiB 单 SSE 行/事件、8000 UTF-16 累计文字；提炼 JSON content 另限 16 KiB UTF-8。
- 提炼候选是运行内草稿；确认后失败的精确变更意图按角色保留、只重试本地并纳入退出处理。
- arm64 本地可体验，x86_64 继续交叉构建/分发检查；不得据此声称 Intel/Sonoma 实机通过。
- 测试使用临时设置和假凭据/网络；不读取或打印日用聊天/密钥，不改变正式登录项、Windows/Minimal Sleep 或真实旧皮肤字节。
- 本会话原地开发、一次最终独立代码评审；推送、标签、草稿及 Release 仍需用户新的明确指令。

## Review Focus

1. NFC 等价字符串、emoji 恰好 200/201 单元及输入法组合输入：不能重复存储、截断字素或保存尚未提交的编辑；Task 1 / 6 固定。
2. 异步初次读档晚到、同 ID 换副本或 v2 修订仍为 0：记忆页必须显示真实已加载资料，不能用空编辑覆盖；Task 4 / 6 固定。
3. 提炼已完成后普通聊天推进请求代次和历史：旧候选仍引用原快照；停止/新提炼后的旧网络结果则必须失效；Task 5 固定。
4. 已确认保存失败后关窗、换肤再退出：意图不能随候选草稿被丢弃，重试也不能再次计费；Task 4 / 5 固定。
5. v1→v2 后再应用人设、追加第13轮或清空历史：记忆和修订都必须保留，缺失的 v2 字段不能当空值修复；Task 2 固定。

---

## 文件与接口地图

| 文件 | 职责 |
| --- | --- |
| 新 `Sources/PetCore/Chat/ChatMemory.swift` | 已确认条目、正文规范化、列表边界 |
| 新 `Sources/PetCore/Chat/MemoryExtraction.swift` | 来源轮次、提炼快照、候选及严格 JSON 解码/去重 |
| 改 `Sources/PetCore/Chat/ChatModels.swift` | 会话携带记忆/修订，所有重建保留，普通聊天提示快照 |
| 改 `Sources/PetCore/Chat/ChatStore.swift` | 显式 v1/v2 读取、v2 写入和保护 |
| 新 `Sources/YeShunguangPet/Chat/DeepSeekTextTransport.swift` | 从既有客户端提取的固定端点/SSE 传输，共用 text/jsonObject 输出选项 |
| 改 `Sources/YeShunguangPet/Chat/DeepSeekChatClient.swift` | 保留 ChatStreaming 接口和默认纯文字行为，委托共用传输 |
| 新 `Sources/YeShunguangPet/Chat/DeepSeekMemoryClient.swift` | 提炼协议/适配；完整结束后一次解码候选 |
| 改 `Sources/YeShunguangPet/Chat/ChatPersistence.swift` | 新增有修订检查的记忆事务，保留 FIFO 和原子落盘边界 |
| 新 `Sources/YeShunguangPet/Chat/ChatMemoryState.swift` | 运行内候选编辑状态和确认后的待存意图值类型 |
| 改 `Sources/YeShunguangPet/Chat/ChatController.swift` | 本地记忆操作、失败重试/退出、统一请求类型、候选寿命 |
| 新 `Sources/YeShunguangPet/Chat/ChatMemoryView.swift` | 原生记忆管理/来源/候选编辑，不自行联网或写档 |
| 改 `Sources/YeShunguangPet/Chat/ChatWindowController.swift` | 四页入口、状态文案、既有模态/关闭/渲染桥接 |
| 改 `Sources/YeShunguangPet/StatusBarController.swift` | 显式注入生产提炼客户端，沿用现有所有权与菜单入口 |
| 改 `Sources/YeShunguangPet/AppDelegate.swift` | 退出保存失败提示包含记忆，流程仍调用控制器汇总/重试 |
| 改 `Tests/Support/ChatFixtures.swift` | 受控提炼替身、记忆事务名称、现有夹具的显式假客户端注入 |

Xcode 使用 XML plist 显式登记：每个新文件建立 PBXFileReference、root group child、PBXBuildFile 和 Sources phase。PetCore 文件只编入 PetCore；每个 Mac 生产源码同时编入 App 和未托管 PetMacTests（两条 build membership）；测试只进其测试 target。不设置 TEST_HOST，不把个人资料作为 bundle 资源。新测试必须在日志中实际列出。

## Task 1：有界记忆、来源及两类提示快照

**Files:** 新建地图中的 `ChatMemory.swift` / `MemoryExtraction.swift` 和 `Tests/PetCoreTests/ChatMemoryTests.swift`；修改 `ChatModels.swift`、`Tests/PetCoreTests/ChatConversationTests.swift`、`YeShunguangPet.xcodeproj/project.pbxproj`。

**Interfaces:**
- public `ChatMemory: Codable, Equatable, Sendable`：只读 `id: UUID` / `text: String`，`init(id: UUID = UUID(), text: String) throws`；`static normalizedText(_ text: String) throws -> String`；`static validate(_ memories: [ChatMemory]) throws`。解码后校验也检查已存文本为规范形式，不在读取时静默改写。
- `ChatConversation` 增加只读 `memories: [ChatMemory]`、`memoryRevision: UInt64`，现有 init 末尾追加默认参数 `memories: [ChatMemory] = []` / `memoryRevision: UInt64 = 0`。新增 `replacingProfile(_ profile: ChatProfile) throws -> Self`、`clearingHistory() throws -> Self`、`replacingMemories(_ memories: [ChatMemory], expectedRevision: UInt64) throws -> Self`。最后一个仅修订匹配且未溢出时加 1；其他重建保留列表与修订。
- `ChatPromptSnapshot` 保留现有 init，增加只读 `memoryRevision: UInt64`，普通提示加入用户确认资料区，空记忆省略新增区以保持原提示；候选不属于其输入。
- public `MemorySourceRound: Equatable, Sendable`：只读 `number: Int` / `user: String` / `assistant: String`。public `MemoryExtractionSnapshot: Equatable, Sendable`：`init(conversation: ChatConversation, model: ChatModel) throws`，只读 `characterID/model/memoryRevision/rounds/memories/messages`；要求1–12轮完整问答，messages 仅固定提炼规则和 JSON 编码的轮次/已存记忆，不能把自定义人设当提炼指令。
- public `ChatMemoryCandidate: Equatable, Sendable`：App 分配的 `id: UUID`、正文 `text: String`、`sourceRounds: [Int]`。public `MemoryCandidateBatch: Equatable, Sendable`：`candidates: [ChatMemoryCandidate]`、`duplicateCount: Int`；通过 public `MemoryCandidateDecoder.decode(_ data: Data, for snapshot: MemoryExtractionSnapshot) throws -> MemoryCandidateBatch` 产生，不由模型决定 ID。

- [x] **1. 写失败用例。** `ChatMemoryTests.testCanonicalTextAndLimits` 核心断言：
  ```swift
  XCTAssertEqual(try ChatMemory(text: " e\u{301} \n").text, "é")
  XCTAssertNoThrow(try ChatMemory(text: String(repeating: "😀", count: 100)))
  XCTAssertThrowsError(try ChatMemory(text: String(repeating: "😀", count: 100) + "x"))
  XCTAssertThrowsError(try ChatMemory(text: " \n\t"))
  XCTAssertThrowsError(try ChatMemory(text: "a\0b"))
  ```
  `testListCapacityDuplicatesAndRevision` 验证 20/21 条、重复 UUID、NFC 等价正文、修订匹配+1/不匹配/UInt64.max 拒绝。`testPromptsKeepMemoriesAfterThirteenRounds` 验证历史首轮变 u2、24条历史、memoryRevision 不变、确认记忆仍在普通 system 中，提炼 messages 不含人设标记或输入草稿。
- [x] **2. 写候选失败用例。** `testCandidateJSONContractAndGroundedSource` 验证 0/5 条可用、6 条拒绝、有效来源 1…实际轮数、重复来源去重、空/0/越界/错误类型来源拒绝；未知/重复键、空/超长/控制正文、任一无效项整批拒绝，16KiB+1 拒绝。`testExactDuplicateCandidatesAreReported` 断言与旧记忆/同批规范化重复只留第一项且 duplicateCount 正确，不做语义去重。
- [x] **3. 运行 RED。** `bash scripts/test.sh -only-testing:PetCoreTests/ChatMemoryTests -only-testing:PetCoreTests/ChatConversationTests`，确认失败来自新行为缺失而非零用例/环境错误，保存日志与退出码。
- [x] **4. 实现上列接口。** 保留旧输入/人设/12轮上限；StrictJSON 在提炼 content 使用 16384 字节参数，校验确切字段后再解码，避免 JSONDecoder 默认忽略未知字段。规范化与去重使用同一函数。
- [x] **5. 运行同一命令 GREEN。** 必须列出新增用例且零失败；原会话用例继续通过。
- [x] **6. 本地提交。** 精确暂存本任务文件与工程，`git commit -m "feat: model confirmed memories and grounded extraction candidates"`。

## Task 2：角色档案 v2 与有序记忆事务

**Files:** 修改 `ChatStore.swift`、`ChatPersistence.swift`、`Tests/Support/ChatFixtures.swift`；扩展 `Tests/PetCoreTests/ChatStoreTests.swift` / `Tests/PetMacTests/ChatPersistenceTests.swift`；不修改主 SettingsStore 或 connection v1。

**Interfaces:**
- `ChatStore` 现有公开接口保持；内部按封装版本选择专用 LegacyConversation（只有 ID/profile/messages）或完整 v2 `ChatConversation`。写出 `{schemaVersion:2,conversation:{characterID,profile,messages,memories,memoryRevision}}`；v2 缺任一新增字段为受保护档案。
- `ChatWriteOperation` 新增 `.memories(characterID: String, expectedRevision: UInt64, memories: [ChatMemory])`。worker 对最新 current 调用 Task 1 重建接口，保存成功才更新缓存；profile/clear 改为 Task 1 保留字段的方法。
- `ControlledChatPersistence.apply` 的 exhaustive switch 增加记录名 `memories:<id>`，沿用 `holdNextWrite/failNext/waitForOperations/releaseWrite`。FIFO ticket/waitForPending 接口保持。

- [x] **1. 写迁移失败用例。** `ChatStoreTests.testV1LoadsWithoutRewriteAndWritesV2OnMutation` 使用手写 v1 JSON，断言读后文件 Data 完全相等、旧人设/12轮相等、记忆空/revision0；明确保存后 schemaVersion2，重开所有字段相同。`testV2MissingInvalidMemoryFieldsRemainProtected` 覆盖缺失/null/错误类型/重复ID/NFC重复/非法修订/未知版本，断言 save 抛错且原字节相等。
- [x] **2. 写事务失败用例。** `ChatPersistenceTests.testMemoriesSurviveProfileAppendAndHistoryClear` 排队记忆→人设→第13轮→clear，最终 history 空、最新 profile/记忆/revision 均保留。`testMemoryRevisionConflictPreservesLatestArchive` 用相同原修订排两次记忆，后者失败且文件/缓存保持第一份。`testFailedAcceptedMemoryWriteCanRetryWithoutLoss` 注入一次失败，原文件/缓存不变，重试同意图一次成功且只增一次修订。`testResetBacksUpAllCharacterData` 断言备份含人设/历史/记忆，重置三者清空且 revision0，备份失败不解除保护。
- [x] **3. 运行 RED。** `bash scripts/test.sh -only-testing:PetCoreTests/ChatStoreTests -only-testing:PetMacTests/ChatPersistenceTests`。
- [x] **4. 实现 v2 和事务。** 读取 v1 不落盘，保留原 2MiB/身份/StrictJSON/权限/备份保护；普通资料写入都输出 v2。复用 FIFO，不从控制器直接调用 store，不让网络 Task 取消已经登记的写入。
- [x] **5. 运行同一命令 GREEN。** 连同原 >128KiB 中文档案、原子写失败、保主配置、FIFO 排序和退出 drain 用例通过。
- [x] **6. 本地提交。** `git commit -m "feat: migrate chat archives and serialize revisioned memory writes"`，仅暂存本任务文件。

## Task 3：复用 DeepSeek 传输并增加提炼客户端

**Files:** 新建 `DeepSeekTextTransport.swift` / `DeepSeekMemoryClient.swift` / `Tests/PetMacTests/MemoryClientTests.swift`；修改 `DeepSeekChatClient.swift`、`Tests/PetMacTests/ChatClientTests.swift`（仅确有必要的适配）、工程。

**Interfaces:**
- internal `DeepSeekOutputFormat: Sendable { case text, jsonObject }`；`DeepSeekTextTransport.init(configuration: URLSessionConfiguration = DeepSeekTextTransport.configuration())`、`static configuration() -> URLSessionConfiguration`、`stream(model: ChatModel, messages: [ChatMessage], format: DeepSeekOutputFormat, apiKey: String) -> AsyncThrowingStream<ChatStreamEvent, Error>`。
- 保留 `ChatStreaming`、`DeepSeekChatClient.init(configuration:)` / `configuration()` / `stream(_:apiKey:)`；普通聊天委托 format .text，不新增 response_format 或其他行为变化。
- internal `protocol ChatMemoryExtracting: Sendable`：`extract(_ snapshot: MemoryExtractionSnapshot, apiKey: String) async throws -> MemoryCandidateBatch`。`DeepSeekMemoryClient.init(configuration: URLSessionConfiguration = DeepSeekTextTransport.configuration())` 实现该协议，调用 .jsonObject、累计文字并在 completed 后调用 Task 1 解码器。

- [x] **1. 写失败用例。** 新 `MemoryClientTests` 使用自己独立的私有 URLProtocol（不访问 ChatClientTests 的 file-private 静态夹具）。`testExtractionRequestUsesJSONModeAndFrozenSource` 检查固定 POST/来源、Bearer 假密钥、stream true/thinking disabled/max_tokens2048/response_format json_object、索引问答与旧记忆、无自定义人设/草稿/其他角色。分成7字节网络片段返回，断言候选与来源正确。
- [x] **2. 写传输失败用例。** `testExtractionRejectsEmptyTruncatedInvalidAndOversizedResults` 验证无 DONE/非stop/空content/非法候选/16KiB超限均失败；`testCancellationAndHTTPFailureNeverRetry` 等待实际 URLProtocol.stopLoading 的限时 expectation，断言请求数1。检查重定向/非官方最终来源、内容类型、断流和既有总量界限；不改用固定 Task.yield 次数判断取消。
- [x] **3. 运行 RED。** `bash scripts/test.sh -only-testing:PetMacTests/MemoryClientTests -only-testing:PetMacTests/ChatClientTests`。
- [x] **4. 实现传输提取和适配。** 从现有客户端搬移端点/认证/无缓存Cookie/重定向拒绝/超时/SSE/错误映射，保留终止取消机制。JSON 只是新增 body 选项；内存客户端仅完整完成后返回，不逐段发布候选，不自动回退或重试，不输出原始异常正文。
- [x] **5. 运行同一命令 GREEN。** 既有 ChatClientTests 全部通过，新增用例实际执行；新传输同时登记 App/PetMacTests。
- [x] **6. 本地提交。** `git commit -m "feat: extract memory candidates through shared DeepSeek transport"`，精确暂存。

## Task 4：本地记忆命令、保存失败及退出汇总

**Files:** 新 `ChatMemoryState.swift` / `Tests/PetMacTests/MemoryControllerTests.swift`；修改 `ChatController.swift`、`ChatFixtures.swift`、`AppDelegate.swift`、`ChatWindowController.swift`（新增状态的最小呈现）、工程。

**Interfaces:**
- internal `PendingMemoryChange` 含唯一 token、characterID、expectedRevision、确认后的完整 `[ChatMemory]`；是精确保存意图，不包含需要再次调用模型的动作。
- `ChatController` 新增只读 `canEditMemories: Bool` / `canRetryMemorySave: Bool` / `pendingMemoryCharacterIDs: [String]` / `memoryEditRevision: UInt64`；`saveMemory(id: UUID, text: String, for context: ChatCharacter, expectedRevision: UInt64)`、`deleteMemory(id: UUID, for context: ChatCharacter, expectedRevision: UInt64)`、`clearMemories(for context: ChatCharacter, expectedRevision: UInt64)`、`retryPendingMemorySave()`、`discardPendingMemorySave()`。Task 5 的候选确认也复用同一个私有登记入口。
- 扩展原 `hasPendingWrites` / `terminationSaveError` / `canRetryTerminationSave` / `retryAllPendingSaves()`，汇总所有角色失败意图；已有已接受写入等待和请求取消规则保持。`ChatState` 增加 `.unsavedMemory`，同任务更新 ChatWindowController 的 exhaustive switch 为「记忆变更尚未保存」，不能误标为完整聊天回复未保存或留到Task6才修复编译。

- [x] **1. 写失败用例。** `MemoryControllerTests.testMemoryMutationsCommitBeforeBecomingEffective` 使用真实 worker/临时目录与受控写入，确认写完成前 conversation 仍旧、成功后 revision+1；改/删/全部清除保留 profile/history。错误 context/skinRevision/expectedRevision 不接受写入。离线/AI关闭可编辑已有记忆，受保护/模态/睡眠/退出/角色待存时拒收。
- [x] **2. 写退出失败用例。** `testFailedConfirmedChangeSurvivesWindowCloseSkinChangeAndTermination` 注入 `memories:robin` 失败，关窗→hutao→同ID不同revision重开，断言 robin 意图仍在，旧有效记忆不变，其他角色仍可用；retryAllPendingSaves 无新增凭据读取或网络请求、只写目标角色一次且清除退出错误。`testAcceptedMemoryWriteFinishesAfterClosing` 挂起写入后关闭/换角色，再放行，保存属于旧角色且当前窗口不显示旧内容。
- [x] **3. 运行 RED。** `bash scripts/test.sh -only-testing:PetMacTests/MemoryControllerTests -only-testing:PetMacTests/ChatPersistenceTests -only-testing:PetMacTests/ChatControllerTests`。
- [x] **4. 实现命令和失败意图。** 接受前同步登记；worker 回执按角色/ticket/token 处理，成功才有效，失败保留精确列表及修订。未处理前禁当前角色发送/提炼/资料修改；retry 复用原意图，discard 保旧有效值。既有 profile/history/credential 回执不能误清 memory pending。初次异步读档及成功记忆变更推进 memoryEditRevision，以免空编辑覆盖新资料。
- [x] **5. 运行同一命令 GREEN。** 既有完整问答、本地重试及退出用例保持；AppDelegate 继续调用原汇总方法，只调整提示覆盖记忆，不新增独立循环/网络重试。
- [x] **6. 本地提交。** `git commit -m "feat: preserve confirmed memory save intents across lifecycle changes"`，精确暂存。

## Task 5：单飞提炼、候选确认和生命周期

**Files:** 修改 `ChatMemoryState.swift` / `ChatController.swift` / `StatusBarController.swift` / `ChatWindowController.swift`（新增状态的最小呈现）/ `ChatFixtures.swift` / `Tests/PetMacTests/ChatControllerTests.swift`；新 `Tests/PetMacTests/MemoryExtractionTests.swift`，登记工程。

**Interfaces:**
- `MemoryReviewState` 含 App 分配批次 id、完整 ChatCharacter、冻结 MemoryExtractionSnapshot、候选及其运行内编辑文本/选中ID。提炼完成时才建立；初始选中集合为空。
- `ChatController.init` 明确增加 `memoryClient: any ChatMemoryExtracting`（不提供真实网络默认值），更新生产 StatusBar、夹具和原重开测试三个调用点。新增 `memoryReview: MemoryReviewState?`、`isExtractingMemories: Bool`、`canExtractMemories: Bool`；方法 `extractMemories()`、`setMemoryCandidateText(id: UUID, text: String)`、`setMemoryCandidateSelected(id: UUID, selected: Bool)`、`saveSelectedMemories(reviewID: UUID, for context: ChatCharacter)`、`discardMemoryReview()`。
- internal `ChatRequestKind { case conversation, memoryExtraction }`，共享原 requestTask/generation/凭据/停止门控；`ChatState` 新增 `.extractingMemories`，同任务更新窗口 exhaustive switch 为「正在提炼记忆」。提炼不能操作聊天 draft/provisional input/partial reply 或 onFeedback。完成候选寿命靠批次id和上下文，不用后来普通聊天的网络 generation 否定已完成批次。
- 夹具新 `ControlledMemoryClient: ChatMemoryExtracting`：线程安全 `count`、`snapshot(_ index: Int) -> MemoryExtractionSnapshot?`、`complete(_ index: Int, json: String)`（按该次快照走真实候选解码）、`fail(_ index: Int)`、`finishAll()`。能挂住请求直到测试明确完成，故可投递取消后的晚到结果；`ChatControllerFixture` 注入此假客户端并在 close 释放。原 `ControlledChatClient` 新增线程安全 `snapshot(_ index: Int) -> ChatPromptSnapshot?`，供用例检查普通发送范围，不读取私有数组或访问真实服务。

- [x] **1. 写失败用例。** `MemoryExtractionTests.testCandidatesRequireExplicitSelectionAndNeverEnterChatUntilSaved` 先保存一轮，提炼后断言 history/draft/磁盘/feedback 均未变、selectedIDs空；不选保存不写盘，选/编辑后保存才出现记忆。超过剩余数量、编辑后完全重复或过长时拒绝并保留编辑，不截断。已满20/无完整轮/待存/连接错误/模态等门控不触发读取密钥或请求。
- [x] **2. 写代次和寿命失败用例。** `testCompletedReviewSurvivesNormalChatButKeepsOriginalSources` 提炼后发送第13轮，断言候选批次和来源原话不变、普通 chat snapshot 不含候选；保存后下一请求含记忆。`testLateExtractionCannotReviveDiscardedBatch` 分别在凭据读取/提炼阶段停止、关闭、成功换肤含同ID、睡眠、关AI和退出后投递旧结果，断言不出现候选、不写档、不反馈、不自动再请求。最小化/隐藏角色/安静/专注与单纯页面切换不取消明确提炼。
- [x] **3. 写草稿与待存分离用例。** `testMemoryReviewInvalidationDoesNotLoseAcceptedIntent` 覆盖应用新人设/记忆变更/clear/reset/关窗/换肤/退出丢未确认批次，但确认保存失败的意图保留；已完成候选在睡眠/关AI后仍可本地确认（醒来后才可操作）。`testAIRequestKindsAreSingleFlight` 验证 chat↔提炼互斥、模型/密钥修改禁用、AIoff始终能取消、停止文案区分、取消退出不重启请求。
- [x] **4. 运行 RED。** `bash scripts/test.sh -only-testing:PetMacTests/MemoryExtractionTests -only-testing:PetMacTests/MemoryControllerTests -only-testing:PetMacTests/ChatControllerTests -only-testing:PetMacTests/ChatLifecycleTests`。
- [x] **5. 实现上述状态与桥接。** 提炼冻结当前已存轮次/记忆，经过按需凭据读取后发一次请求；成功只发布临时候选。确认时再检查批次/完整角色/记忆修订/当前门控，用 Task 4 保存入口登记完整新列表；每条新记忆由 App 分配UUID。保存失败的列表和批次草稿分离。再次提炼要求先明确丢旧候选；连接、主配置、桌宠调度不新增后台请求或计时器。
- [x] **6. 运行同一命令 GREEN。** 记录实际用例，重新核对仅三个生产/测试初始化调用点都显式传入对应客户端，无测试默认落到真实网络。
- [x] **7. 本地提交。** `git commit -m "feat: coordinate explicit extraction and user-approved memory batches"`，精确暂存。

## Task 6：原生记忆页、模态与说明

**Files:** 新 `ChatMemoryView.swift` / `Tests/PetMacTests/MemoryWindowTests.swift`；修改 `ChatWindowController.swift`、`Tests/PetMacTests/ChatWindowTests.swift` / `ChatIntegrationTests.swift`、`Sources/YeShunguangPet/Settings/HelpSettingsView.swift`、`Sources/YeShunguangPet/Info.plist`、README、工程。

**Interfaces:**
- internal `@MainActor final class ChatMemoryView: NSStackView`，`init(controller: ChatController, hasBlockingModal: @escaping () -> Bool, confirm: @escaping (String, String, @escaping () -> Void) -> Void)`、`render()`、`resetDrafts()`；由窗口持有并在既有 render/关闭/上下文变化时调用。视图只调用 Task 4/5 API，不持有网络/文件服务。
- 四页次序「对话 / 人设 / 记忆 / 连接」，保留原窗口520×620/最小440×420和单一外层滚动。页面切换不重建服务或丢候选；人设仍遵循原切页弃草稿规则。旧索引测试随页面语义更新，不误将连接页当人设页。
- 记忆页用纯文字原生控件，列表单项进入编辑；候选有勾选、编辑、可展开用户原话来源。点击删除/全部清除时调用现有 confirm helper，modal结束后用捕获 context/revision 再调用控制器。保存按钮须检查所有相关 NSTextView.hasMarkedText，且 action本身再次检查，不只按钮enabled。

- [x] **1. 写失败用例。** `MemoryWindowTests.testFourPagesAndAsyncArchiveLoadNeverOverwriteEditor` 挂起初次load再放行已存记忆，断言新页面展示正确；后续状态刷新不覆盖用户编辑，同ID skinRevision变化和关窗则重置未确认编辑。`testMemorySaveRejectsMarkedTextAtActionBoundary` 给候选/已有条目构造marked text，按钮及直接action均不写盘，unmark后才能保存；NFC/200单元边界沿用Task1。
- [x] **2. 写模态及状态失败用例。** `testDeleteDispatchesOnlyAfterModalEndsAndRevalidatesContext` 模态时禁止普通发送/提炼/保存，结束后重新检查身份/修订，模拟换角色或睡眠则不接受旧动作。`testReviewSelectionSourcesAndFailureRecovery` 验证默认未勾选、来源为本地快照、满额/重复/保存失败清晰、retry只本地、AIoff可编辑本地、提炼中显示停止而非JSON、普通聊天原输入/复制/停止保持。
- [x] **3. 运行 RED。** `bash scripts/test.sh -only-testing:PetMacTests/MemoryWindowTests -only-testing:PetMacTests/ChatWindowTests -only-testing:PetMacTests/ChatIntegrationTests`。
- [x] **4. 实现原生页与生命周期渲染。** 仅当context、memoryEditRevision或批次结构变化时重建编辑控件；普通状态/每段流式更新不覆盖光标和草稿。候选文字变化不反复重建行。完成态和error状态区分聊天/记忆，关闭、换肤、成功变更按设计清草稿，确认后失败意图仍从控制器展示。来源原话不进诊断或剪贴板自动复制。
- [x] **5. 更新使用说明及版本。** 连接页说明普通发送包含人设/已确认记忆/12轮/本次输入，提炼会额外发送当前已存问答和记忆；按钮旁说明额外计费与候选寿命。帮助解释删除独立记忆不移除历史里的同文、清空/重置范围、v2回退旧版保护。Info.plist改0.3.0/build25，仅更新当前介绍，不改历史验收/版本比较夹具。
- [x] **6. 运行同一命令 GREEN。** 隔离原生浅深色、最小尺寸和长来源滚动渲染；程序化操作与缓存不能记作实际物理鼠标/输入法/焦点实测。
- [x] **7. 本地提交。** `git commit -m "feat: manage and confirm character memories in the native chat window"`，精确暂存。

## Task 7：回归、一次整体评审与本地交付

**Files:** 新 `docs/character-memory-validation.md`，更新 README / TODO.md / AGENTS.md / 本计划状态；日志、隔离夹具、探针和安装备份仅存忽略目录 `.build/character-memory-validation/`，产物仅 `dist/`。仅在实际发现回归时修改对应源码/测试。

**Interfaces:** 复用既有 `bash scripts/test.sh`、`bash scripts/build-app.sh [arm64|x86_64]`、`bash scripts/package-app.sh [arm64|x86_64]`、`python3 scripts/smoke-app.py` 和发版离线检查；不新增用户可见测试模式或生产后台任务。

- [ ] **1. 运行完整相关检查。** `bash scripts/test.sh` 与 `python3 -m unittest discover -s Tests/Release -v`。原生须 `TEST SUCCEEDED`、零失败且新类实际执行；离线发版预期现有13项。保存命令/退出码/实际数量，不能沿用0.2.0的372项作为新结果。环境失败先与行为失败区分，不删失败日志。
- [ ] **2. 运行优化同源隔离探针。** 使用现有测试架构建立仅本地 `.build` 探针，假凭据/假网络、真实三套旧皮肤、临时配置；走提炼→来源/编辑/勾选→保存→超过12轮→重开读取、角色隔离/同ID共用、保存失败跨角色本地重试、满额、清空历史保记忆、清记忆保历史、取消晚到和退出等待。AppKit真实窗口控件与缓存渲染记录场景及source SHA；不读个人聊天/密钥，不发真实提炼请求。
- [ ] **3. 一次最终独立整体评审。** 按已保留Native流程，用当时可用的最强合适评审模型，对产品基线 `2c15595` 到最终功能提交整体只读评审；重点为确认前不写盘、v1/v2、单飞/晚到/失败意图、模态、普通聊天回归。按证据处理问题，阻断项先新增失败回归再修，重跑受影响用例和完整原生/离线发版；不另开第二次独立代码评审。
- [ ] **4. 固定干净来源并构建两个架构。** 将功能和必要修复本地提交，确认tracked无脏改；依次运行 `bash scripts/build-app.sh arm64`、`bash scripts/build-app.sh x86_64`，两者实际 `BUILD SUCCEEDED`。核对 build-info 的完整SHA/clean、0.3.0/build25、原生单架构及Mach-O14.0，不以旧dist冒充新构建。
- [ ] **5. 打包与分发检查。** 依次运行 `bash scripts/package-app.sh arm64` / `bash scripts/package-app.sh x86_64`，再 `python3 -m unittest discover -s Tests/Distribution -v`；预期现有13项，若新增则据实计数。核对签名/依赖/原素材/许可证/库存/摘要和用户数据排除。将本次八份DMG/ZIP/sha256复制到专用空暂存目录，以 `python3 scripts/prepare-release.py --assets STAGING_DIR --version 0.3.0 --commit FULL_SHA --check-only` 离线检查；不调用任何远端写入。
- [ ] **6. ARM 离工程实际启动/重开。** 从本次DMG复制到真正中文与空格目录，弹出DMG，以 `python3 scripts/smoke-app.py --app MOVED_APP_PATH --check-restore --output .build/character-memory-validation/moved-smoke.json` 验证启动、正常退出和再开；工具自己建立隔离设置路径并排除开发环境依赖。核对独立架构、版本、来源、主配置保留和基础窗口。记忆路径由Step2优化同源探针验证，不能把假网络探针写作分发二进制真实DeepSeek提炼通过。
- [ ] **7. 本地日用安装。** 按准确路径正常退出 `/Applications/YeShunguangPet.app`，等待原已接受文件变更；备份原App和退出后的文件，再替换本次arm64 App。不解析/打印个人AI档案或读取正式Keychain；核对主schema13及既有偏好/皮肤/退出位置/快捷键/计时窗/时长/统计保留，原AI文件保持直到App按正常使用保存。若仍有未解决保存失败，不强杀覆盖。核对启动版本/自身PID/窗口，不自动改登录项或发API请求。
- [ ] **8. 记录并交付。** 验证文档写清实际source、每项命令/数量/退出码、单次评审结果、原失败和修复、本地安装/备份、已测与未测；更新TODO/AGENTS/计划状态并本地提交。提供arm64 App/DMG绝对路径和用户验收要点：真实提炼、来源/修改/勾选、重开记忆、普通聊天能否参考记忆。用户未执行前标记未测；真实系统睡眠/输入法/焦点/Spaces/Gatekeeper和Intel/Sonoma仍按证据，不因旧版反馈自动通过。文档提交不改变干净包来源，不擅自推送/打标签/发布。

## Plan Self-Review / 审核与执行状态

计划自审由主执行者完成，不另派计划评审代理。设计第1–4节由Task1/5/6覆盖，第5节由Task1/3覆盖，第6节由Task2/4覆盖，第7节由Task4/5/6覆盖，第8节及交付由Task7覆盖。Review Focus五项已各指定失败用例；检查了跨任务类型/签名、原夹具穷尽switch、三处初始化注入、App与未托管Mac测试的双重源码登记、私有网络夹具不可跨文件复用、元数据唯一来源与八附件隔离暂存。

用户已认可计划，沿用本会话Native方式连续实施，不逐任务再确认；实际进度以任务勾选、当前计划ledger和验证文档为准。推送/标签/Release不在本计划授权内。
