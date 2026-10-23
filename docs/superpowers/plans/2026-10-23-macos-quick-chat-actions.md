# 桌面轻聊天与确认操作 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付共享原聊天与记忆的角色旁轻聊天窗，并让DeepSeek提出经用户确认、按真实状态执行的专注与手动安静操作。

**Architecture:** PetCore定义受限操作、运行快照和纯文字回执；Mac传输对普通文本、记忆JSON和带工具聊天明确分模式。操作桥复用FocusController/PetSession；ChatController统一请求、候选与已接受结果，复用原FIFO保存完整问答。统一呈现协调器管理完整/快速两个原生窗口，交接保持会话，真实关闭才取消未接受内容。

**Tech Stack:** Swift6、AppKit、Foundation URLSession、Combine、既有Security/CryptoKit/XCTest；macOS14+、系统框架、现有Xcode，无新增依赖。

**Spec:** [用户已认可的设计](../specs/2026-10-23-macos-quick-chat-actions-design.md)。用户于2026-10-23明确「认可书面设计，进入实施计划」，此前已选DeepSeek自然语言理解及卡片确认。

**执行方式:** 保留Native：主执行者在本会话原地逐任务TDD、自测和本地提交，最后一次独立整体代码评审；辅助代理仅做只读事实核对，不逐任务派实现/评审代理、不再询问执行方式、不新增工作树。

**状态:** 实施计划已自审，等待用户审核；尚未编写产品代码或执行本版功能测试。仓库`/Users/resker/develop/github/YeShunguangPet-macOS`，分支`codex/macos-quick-chat-actions`，产品基线`b154e6bd347f858730ff171fc8a265abc8bd523b`，设计初稿`2700550`；下列路径从仓库根起算。计划获准后仅建立本计划执行账本`.superpowers/sdd/2026-10-23-macos-quick-chat-actions/progress.md`，不得恢复/删除已归档0.3.0或其它计划工作区。

## Global Constraints

- 交付 **0.4.0/build26**，Swift6/AppKit/macOS14+；兼容本机Swift6.4和云端6.3.3。
- 每轮最多一个操作候选；仅`start_focus(minutes:1–120 JSON整数)`、`pause_focus({})`、`resume_focus({})`、`set_quiet(enabled:JSON布尔)`。分别仅focus/ready、focus/running、focus/paused及手动安静明确目标值；无重置/自动跳段/覆盖进行中计时。
- 每次先卡片确认；确认重新校验角色/代次/状态/修订、模态/睡眠/退出；同一候选进程内最多执行一次，ABA不能恢复旧卡。开始专注先保存常用专注时长，休息时长保留；关闭手动安静不解除专注安静。
- 同一全局AI请求门控；普通请求使用当前DeepSeek官方端点、模型与Keychain项，非思考、stream:true、max_tokens2048，附4个tools及tool_choice:auto。确认/取消/本地重试无额外API或凭据读取，无自动工具循环/重发/备用模型/Beta端点。
- 请求/总响应1MiB、SSE单行/事件64KiB、30秒闲置/120秒总时限、文字8000 UTF-16；工具id非空无控制字符且最多256 UTF-16，arguments最多4096 UTF-8。严格字段/JSON/重复键/类型/索引/完成验证；记忆JSON仍16KiB、不接受tools。
- 输入2000 UTF-16、Enter换行、⌘Enter发送；marked text在按钮/action/界面交接再检查，不截断字素或强制提交。小窗约360×300、最小320×240、失焦保留、只由明确打开动作取焦点；角色仍不可key/main。
- 完整/快速同一时刻仅一种显示，共享角色/草稿/选择/请求/候选/回执待存；交接不是关闭。轻窗跟随角色、无新增位置持久化/全局快捷键/轮询，隐藏桌宠仍可用，App隐藏按原规则。
- 工具提议不落盘，执行/明确取消形成user/assistant完整纯文字回执；主schema13/角色v2及12轮、人设/记忆保持。执行后存盘失败不重复操作，丢弃回执不撤销已执行结果，已接受意图跨关窗/角色/退出保留。
- 原0.3.0两项Minor在本轮相关组件修复并补回归；历史原失败/验证边界不改写为通过。
- 临时配置、假网络/凭据、真实旧素材原字节；不读私人AI/正式Keychain、不改登录项/Windows/Minimal Sleep，不添加生产测试模式或新权限。
- 本地arm64交付，x86_64交叉构建核验；真实DeepSeek、物理IME/焦点/睡眠/Spaces/Gatekeeper/Intel实机按实际证据，推送/标签/Release另等明确指令。

## Review Focus

1. 确认调用的同步回调关窗/换肤/开始退出：本地操作结果仍归确认角色，重试存档不能再执行；Task4。
2. 倒计时自然变化不使卡片过期，但暂停→继续、安静开→关等ABA必须失效；临界到期先结算再检查，不能把继续误当下一段；Task3/4。
3. 完整窗隐藏后的晚到close/visibility回调，及从人设/记忆页交接：不能取消新窗口请求、丢记忆编辑、把chatPresented误置false或清新草稿；Task5/6。
4. 既有冻结来源的记忆候选与操作卡、回执失败同时存在：先处理操作，不静默丢候选或把新历史当旧来源；Task4/5。
5. 真实普通文字前缀后才到tool_calls、空content工具回合、参数跨UTF-8分片或终止后再给数据：不能提前存盘、执行或把普通完成当工具确认；Task2。

---

## 文件地图与登记

| 文件 | 职责 |
| --- | --- |
| 新`Sources/PetCore/Chat/ChatAction.swift`、`ChatAppSnapshot.swift`；改`ChatModels.swift` | 操作/严格参数、回执、稳定命令stamp与请求资料 |
| 改Mac Chat目录`ChatSSEDecoder.swift`、`DeepSeekTextTransport.swift`、`DeepSeekChatClient.swift`、`DeepSeekMemoryClient.swift`；新`DeepSeekChatTools.swift` | 有界工具分片、三种传输模式及工具定义 |
| 新`Chat/ChatActionBridge.swift`；改`FocusController.swift`、`PetSession.swift` | 类型化本地执行、真实状态/修订、独立观察 |
| 新`Chat/ChatActionState.swift`；改`ChatController.swift`、`Tests/Support/ChatFixtures.swift` | 待确认/执行中意图与回执保存，显式假依赖 |
| 新`Chat/ChatPresentationCoordinator.swift`、`ChatActionCardView.swift`；改`ChatWindowController.swift` | 唯一呈现所有者、交接/真实关闭、完整窗卡片 |
| 新`Sources/PetCore/Placement/QuickChatPlacement.swift`、`Chat/QuickChatWindowController.swift` | 轻窗纯几何与原生呈现，窗口不持有服务 |
| 改`StatusBarController.swift`、`AppDelegate.swift`、`Settings/HelpSettingsView.swift`、`Info.plist`、README | 入口、所有模态/退出、帮助和元数据 |
| 新`docs/quick-chat-actions-validation.md`；改TODO/AGENTS/本计划 | 实际验证、风险、交付与用户待验收 |

已核对现有纯定位文件为`Sources/PetCore/Placement/WindowPlacement.swift`，QuickChatPlacement同目录，不新增平行Geometry层。Xcode为XML plist显式登记：Core源进PetCore，Mac源同时进App和未托管PetMacTests，测试只进对应测试target；不设置TEST_HOST。登记与首次引入源/测试同任务，避免后任务补编译破口。

## Task 1：操作合同、快照与普通请求提示

**Files:** 新上述两个Core文件、`Tests/PetCoreTests/ChatActionTests.swift`；改`ChatModels.swift`与工程。

**Interfaces:** `public enum ChatAction: Equatable, Sendable { case startFocus(minutes:Int), pauseFocus, resumeFocus, setQuiet(enabled:Bool) }`；`ChatActionDecoder.decode(name:String,arguments:Data) throws -> ChatAction`。`ChatAppSnapshot: Equatable,Sendable`含`focusRevision/quietRevision:UInt64`、`phase:FocusPhase`、`status:FocusStatus`、`focusMinutes/breakMinutes/remainingSeconds:Int`、`manualQuiet/focusQuiet:Bool`，显式init同名参数；`.commandStamp:ChatActionStamp`；ChatActionStamp为Equatable/Sendable结构，含上述两种修订、phase/status、两种配置时长及两种安静布尔，排除remainingSeconds。`ChatActionReceipt`含action、`Outcome(applied/alreadySatisfied/failed/cancelled)`、本地detail及`assistantText:String`（前缀「【App操作回执】」）。`ChatActionExecutionResult { case expired(String), finished(ChatActionReceipt) }`。`ChatPromptSnapshot`新增`public let appSnapshot:ChatAppSnapshot?`及同名默认nil初始化参数，默认保留旧提示；非nil时加入固定操作规则和只含设计指定运行字段的资料，不发送修订/路径/统计。

- [ ] **1. 写失败用例。** `testActionArgumentsRejectWrongTypesAndUnknownFields`断言1/120可用、0/121/1.5/true/缺字段/重复键/额外键/未知工具/非空pause对象拒绝，enabled只收布尔；4097字节拒绝。`testStampIgnoresCountdownButDetectsRevisionAndState`手工构造快照，只改秒数stamp相等，修订/phase/status/两种时长/安静组件任一改变不等。`testPromptAddsReadOnlyRuntimeWithoutChangingMemoryContract`确认nil保旧行为，非nil有人设/已存记忆/12轮/输入与4种边界、无私人路径/修订；MemoryExtractionSnapshot不含App状态，回执validate可进入原完整问答。
- [ ] **2. 运行RED。** `bash scripts/test.sh -only-testing:PetCoreTests/ChatActionTests -only-testing:PetCoreTests/ChatConversationTests -only-testing:PetCoreTests/ChatMemoryTests`；保存新API缺失的失败证据。
- [ ] **3. 实现上述合同。** StrictJSON按4096字节验证，确切字段/数值与布尔类型，拒绝非法字符串和未知函数；快照资料单独编码，固定指令置于用户自定义资料之外，不能把历史或记忆解析成操作。回执detail采用ChatText校验，不能塞原始异常路径/模型参数。
- [ ] **4. 同命令GREEN并提交。** 记录实际数量、TEST SUCCEEDED；精确暂存Core/测试/工程，`git commit -m "feat: model confirmed app actions and runtime context"`。

## Task 2：有界工具流与现有传输兼容

**Files:** 上述Mac传输/工具文件，`Tests/PetMacTests/ChatActionClientTests.swift`；改`ChatController.swift`最小穷尽switch、工程；既有`ChatClientTests.swift`/`MemoryClientTests.swift`保持行为断言。

**Interfaces:** `ChatStreamEvent`新增终态`.action(ChatAction)`，只在完整tool_calls+[DONE]后发一次，工具回合不再发`.completed`；原`.delta(String)`和纯文字`.completed`不变。`ChatSSEDecoder.Mode { textOnly, chatActions }`、`init(mode:Mode = .textOnly)`；`DeepSeekOutputFormat`增加`.chatActions`。`DeepSeekToolDefinition:Encodable,Sendable`及`DeepSeekChatTools.definitions:[DeepSeekToolDefinition]`提供4个精确function定义（DTO只在此文件，不用Any编码工具库）。`DeepSeekChatClient.stream`仅在snapshot.appSnapshot非nil时启用工具模式；提炼仍jsonObject/textOnly，遇action防御性失败。Task4前Controller收到action先走明确失败占位，保证此任务完整编译但不执行功能。

- [ ] **1. 写失败用例。** `testToolRoundCompletesOnlyAfterArgumentsAndDone`用受控SSE分片拼start_focus25（含UTF-8跨字节、空content、先有文字），DONE前零action，完成后恰一action且无completed。`testMalformedOrMultipleToolsNeverComplete`覆盖多项、错/布尔index、冲突id/name/type、未知名、错误/重复JSON、4097字节参数、256/257单元id、空content+stop、tool载荷+stop、缺工具+tool_calls、重复finish/DONE前终止后载荷、缺DONE与取消晚到。`testRequestsSeparateActionsFromMemoryJSON`检查实际URLProtocol请求：同一固定端点、4tools/tool_choice:auto、非思考和原时限，记忆无tools，拒绝后无重发，密钥不写持久文件。原纯文字/JSON限额和redirect/HTTP/超时用例继续。
- [ ] **2. 运行RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatActionClientTests -only-testing:PetMacTests/ChatClientTests -only-testing:PetMacTests/MemoryClientTests`。
- [ ] **3. 实现分模式解析与工具定义。** 严格index0单项、字段一致、累计字节上限；textOnly看到工具载荷即拒绝。收齐DONE即终结读取，不扫描未读尾部。共享session配置/取消/限额/错误，不复制网络栈、不添加未被文档支持的parallel字段；所有新增event穷尽switch在本任务更新。新测试文件使用独立private ActionURLProtocol（锁保护、按请求等待停止回调），不引用ChatClientTests/MemoryClientTests文件内private夹具、不放松其已有断言。
- [ ] **4. 同命令GREEN并提交。** 核对取消用例等待真实URLProtocol回调而非固定yield次数，保留请求次数断言；`git commit -m "feat: decode bounded DeepSeek action proposals"`。

## Task 3：真实计时和安静操作桥

**Files:** 新`ChatActionBridge.swift`、`Tests/PetMacTests/ChatActionBridgeTests.swift`；改FocusController/PetSession与工程。

**Interfaces:** `@MainActor protocol ChatActionExecuting:AnyObject { var onChange:(()->Void)? {get set}; func snapshot()->ChatAppSnapshot; func execute(_ action:ChatAction,expected:ChatAppSnapshot)->ChatActionExecutionResult; func dispose() }`。`FocusChatActionBridge.init(session:PetSession,focus:FocusController,canDispatch:@escaping()->Bool)`实现协议。Focus新增`@Published private(set) var actionRevision:UInt64`，实际phase/status/时长变化推进、同值刷新不推进；PetSession新增`private(set) var quietRevision:UInt64`、`var onQuietChange:(()->Void)?`，手动/专注安静实际变化推进。桥独立订阅actionRevision，延后读取已更新值，不能覆盖FocusMenus持有的focus.onChange；仅持有自己的quiet观察及Cancellable，dispose不清别人的回调。

- [ ] **1. 写失败用例。** `testStartPersistsDurationBeforeTimerAndFailureDoesNotStart`用真实临时SettingsStore/FocusController，25与1/120开始前保存、保留休息时长；保护/写失败不启动，返回typed失败而非看Void返回。`testPauseResumeRejectCompletedAndRest`临界时刻先refreshTime，完成后旧继续不能进休息；rest任何态拒绝这两个工具。`testStampRejectsABAButNotOneSecondTick`暂停/继续与手动开/关回原值仍过期，每秒变动不失效；设置时长改走再改回也过期，非当前phase的配置时长变化也推进修订。`testQuietNoopKeepsFocusQuietAndObservers`明确目标已满足返回alreadySatisfied，关闭手动安静不解除focusQuiet；原FocusMenus回调及菜单同步仍工作，无递归刷新/新定时器。
- [ ] **2. 运行RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatActionBridgeTests -only-testing:PetMacTests/FocusCompanionTests -only-testing:PetMacTests/FocusPresetStatisticsTests`。
- [ ] **3. 实现操作桥。** snapshot先settle当前时间，桥的重入保护覆盖同步状态回调；execute先独立全局门控与stamp校验，按原applyDurations/startOrResume/pause/setQuiet入口执行，之后读真实状态形成typed回执。以actionRevision替代原private commandGeneration，作为既有FocusCommand/FocusPresetCommand的共用代次；比较phase/status及缓存的两种配置时长，覆盖菜单/预设/设置/自然完成全部路径，非当前段时长改变也推进。每秒剩余变化只更新显示、不推进修订；原onChange在显示或命令stamp改变时保留一次通知，不能另设漂移计数。状态观察只通知候选可能失效，不自动执行。保留原onChange及已验证通知线程分派。
- [ ] **4. 同命令GREEN并提交。** 正向测试验证实际状态和临时配置，fake计数只用于下一任务的重复调度边界；`git commit -m "feat: execute scoped chat actions against current app state"`。

## Task 4：确认意图、回执与原FIFO

**Files:** 新`ChatActionState.swift`、`Tests/PetMacTests/ChatActionControllerTests.swift`；改ChatController、ChatFixtures、ChatControllerTests及StatusBarController初始化、MemoryWindowTests、工程。

**Interfaces:** `ChatActionProposal`含本地UUID、完整ChatCharacter、request/connection代次、原draft及trim后userInput、action与expectedSnapshot。Controller初始化明确新增`actions:any ChatActionExecuting`（无真实默认），更新实际3处调用：StatusBar、共享fixture、重开测试；生产传Task3桥、测试传专用fake。新增`@Published private(set) var pendingAction:ChatActionProposal?`、`var canDecideAction:Bool`、`var isGeneratingConversation:Bool`、`func confirmAction(id:UUID,for context:ChatCharacter)`、`func cancelAction(id:UUID,for context:ChatCharacter)`、`func refreshActionAvailability()`；ChatState新增awaitingAction。PendingPair新增Kind区分modelReply与actionReceipt(outcome)，沿用原append写入；执行中意图计入hasPendingWrites/退出等待，不写新档案字段。新增`ControlledChatActions`显式snapshot/execute/同步onExecute回调替身；ControlledChatClient新增`propose(_ index:Int,action:ChatAction)`发终态，保留现有snapshot/complete接口。

- [ ] **1. 写失败用例。** `testProposalNeedsExplicitDecisionAndOneRequest`普通发送冻结桥快照，收到action只发布卡：零执行/零append、草稿保留，未决卡阻止发送/提炼/资料写入；确认后一次执行、一次append、零额外凭据/API/feedback；取消零执行但保存一轮本地取消回执。未知/过期ID与直接双调用不执行；.expired只清卡/报错，不形成问答。
- [ ] **2. 写接受边界失败用例。** `testAcceptedReceiptSurvivesSynchronousCloseSwitchAndQuit`让fake桥在execute内同步windowClosed/activate同ID或另ID/beginTermination并重复confirm；结果仍append至原角色且只执行一次，不在新角色显示。`testFailedReceiptRetryNeverExecutesAgain`真实worker注入append失败，关窗/换肤/退出后retryAllPendingSaves只append原回执，执行/请求/凭据次数不增；丢弃回执不撤销功能。成功回执、失败回执与取消回执文案和退出待存分类分别准确。
- [ ] **3. 写生命周期和共存失败用例。** `testDraftAndMemoryReviewSurviveActionRound`等候中改新draft不被清空，已完成记忆候选保留原来源；未决卡/回执待存先处理，成功后恢复记忆确认，13轮裁剪不换来源。`testUnacceptedActionsCannotReviveAfterInvalidation`覆盖stop、关闭、换肤含同ID、睡眠/醒来、AIoff、退出取消、清空/重置/成功资料变更与晚到结果；模态只禁止派发，隐藏/最小化不丢卡。`testClearAndTerminationDiscardUnconfirmedMemoryEditor`在既有MemoryWindowTests先复现0.3.0 Minor1：清历史成功、开始后取消退出都重置已有记忆编辑，失败清空不重置。
- [ ] **4. 运行RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatActionControllerTests -only-testing:PetMacTests/ChatControllerTests -only-testing:PetMacTests/ChatLifecycleTests -only-testing:PetMacTests/MemoryExtractionTests -only-testing:PetMacTests/MemoryControllerTests -only-testing:PetMacTests/MemoryWindowTests`。
- [ ] **5. 实现确认及回执。** 在清pendingAction前先登记执行中原角色意图/消费UUID，不经有副作用的观察回调暴露可重入窗口；桥返回后无论当前窗口代次如何，按原角色登记PendingPair并走既有FIFO。只对未接受卡使用网络代次撤销，回执重试不带bridge闭包。所有草稿清除仍比较originalDraft，已存回执不恢复卡；退出等待包括执行/写入/失败，取消退出不重启请求。snapshot只在普通发送获取，提炼不注入；pendingAction清除不误清memoryReview。修复Minor1的memoryEditRevision推进。
- [ ] **6. 同命令GREEN并提交。** 更新awaitingAction在完整窗的最小穷尽switch显示，所有3处初始化明确依赖且已有测试继续fake网络；`git commit -m "feat: confirm actions once and persist truthful local receipts"`。

## Task 5：共享呈现、完整窗卡片和关闭合同

**Files:** 新`ChatPresentationCoordinator.swift`、`ChatActionCardView.swift`、`Tests/PetMacTests/ChatPresentationTests.swift`、`ChatActionWindowTests.swift`；改ChatWindowController、ChatMemoryView、ChatWindowTests、工程。

**Interfaces:** `ChatPresentationMode { full,quick }`；`@MainActor protocol ChatPresentationHosting:AnyObject`提供`isPresentationVisible/hasBlockingSheet/hasMarkedInput:Bool`、`inputSelection:NSRange {get set}`、`setPresentationCallbacks(onClose:@escaping()->Void,onVisibility:@escaping()->Void)`、`presentForHandoff(selection:NSRange)`、`hideForHandoff()`、`resetLogicalDrafts()`及beginTermination/cancelTermination/dispose。Coordinator初始化`init(controller:ChatController,onPresented:@escaping(Bool)->Void)`，`register(_ host:any ChatPresentationHosting,for mode:ChatPresentationMode)`、`present(_ mode:ChatPresentationMode)`、`closeActive()`、聚合hasBlockingSheet/isQuickVisible及生命周期方法。完整窗hasMarkedInput合并composer、人设字段、记忆页新增`hasMarkedInput:Bool`及当前文字响应者；选择范围按当前UTF-16合法范围夹取但不改正文。Coordinator生命周期方法只管理hosts和呈现，不调用Controller.beginTermination/cancelTermination/dispose（仍由StatusBar各调用一次）。注册后host不再直接调用controller.windowClosed/setPresented；未注册的既有完整窗测试保持原单窗行为。`ChatActionCardView.init(controller:ChatController,hasBlockingModal:@escaping()->Bool)`、`render()`，按钮捕获本地id/context派发Task4方法，无第二重NSAlert。

- [ ] **1. 写失败用例。** `testHandoffKeepsRequestDraftSelectionAndEditor`先用fake hosts验证唯一可见、交接不windowClosed，再用真实完整窗验证部分回复、光标、memoryReview/记忆编辑在full→quick→full保留；marked text或任一host模态时拒绝交接。`testLateHiddenHostCloseDoesNotCloseCurrentHost`交接后模拟旧close/visibility回调，另覆盖full→quick→full后投递第一次full保存的旧回调，新窗请求/候选保留且chatPresented不短暂误置false；当前真实关闭只一次逻辑close，接受写入保持。
- [ ] **2. 写原生卡片及Minor2失败用例。** `testNativeActionCardUsesTypedProposalAndStaleButtonsDoNothing`本地标题含25分钟及常用时长提示，确认前不执行，旧/双按钮action不重复操作，失败回执仅本地重试；菜单模态期间拒绝。`testExtractionDoesNotLabelStoppedPartialAsGenerating`先停止普通partial，再提炼，文字仍标未完成而非生成中；这是0.3.0 Minor2直接复现。人设主动切页的原丢草稿规则保持。
- [ ] **3. 运行RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatPresentationTests -only-testing:PetMacTests/ChatActionWindowTests -only-testing:PetMacTests/ChatWindowTests -only-testing:PetMacTests/MemoryWindowTests`。
- [ ] **4. 实现协调器及完整窗适配。** 交接只orderOut/显示，不close/dispose；注册后的窗口回调交给唯一所有者，每次呈现/关闭推进presentationGeneration并重绑携带该代次的host回调，按activeMode和代次拒绝晚到旧host回调，包含同mode再次显示。进入完整对话页用保留缓存编辑的专用交接路径，不调用带reloadProfile副作用的selectPage(0)；用户主动切页仍用原selectPage。明确关闭才清两host未确认编辑。卡片根据typed提议创建，历史前缀不重建卡或可信来源状态；流式/状态更新不反复重建输入控件。Minor2使用isGeneratingConversation判标签。
- [ ] **5. 同命令GREEN并提交。** 保留现有单窗测试及原onPresentationChange兼容直到Task7接管生产所有权；`git commit -m "feat: share chat presentation and confirmed action cards"`。

## Task 6：角色旁轻聊天与有界布局

**Files:** 新QuickChatWindowController、`Sources/PetCore/Placement/QuickChatPlacement.swift`、`Tests/PetCoreTests/QuickChatPlacementTests.swift`、`Tests/PetMacTests/QuickChatWindowTests.swift`；工程。

**Interfaces:** `QuickChatPlacement.frame(anchor:CGRect,size:CGSize,screens:[ScreenArea])->CGRect?`纯几何：右/左/上择位、8点屏边距、夹取尺寸/位置、负坐标屏幕。`@MainActor final class QuickChatWindowController:NSWindowController,ChatPresentationHosting`，初始化`init(controller:ChatController,session:PetSession,onExpand:@escaping()->Void,canDispatch:@escaping()->Bool)`；拥有ChatComposer、滚动内容、Task5卡片及状态/重试/停止，不拥有网络/Keychain/存储。`render()`和`reposition()`可由原生测试调用；订阅自身/角色frame和屏幕通知并在dispose移除，不新增定时器。

- [ ] **1. 写几何失败用例。** `testPlacementFitsRightLeftTopAndRemovedScreen`断言边缘翻转/夹取、负坐标、多屏/移除屏幕、缩放/大尺寸仍位于选定visibleFrame内；无有效屏幕返回nil，不制造假坐标。输入size超过可用区域时几何缩小到屏内，UI保持内容可滚动。
- [ ] **2. 写原生失败用例。** `testQuickViewSharesComposerAndHandoffWithoutDoubleSending`实际两个host接Task5协调器，Enter换行/⌘Enter单次发送、marked text禁止快捷提交/交接/Esc，跨窗草稿/选择/流式/卡不丢；输入新草稿后render不覆盖。`testLongReplyCardAndErrorRemainReachableAtMinimum`360×300/320×240、浅深色、8000单元回复/长错误/回执失败/操作卡，滚动到底确认入口可达，用户离底时新分片不拉走。`testHiddenPetAndFrameEventsDoNotCloseOrTakeFocus`隐藏桌宠保持轻窗，失焦不关闭、后续reposition不makeKey，换肤重新定位；仅记录程序化证据。
- [ ] **3. 运行RED。** `bash scripts/test.sh -only-testing:PetCoreTests/QuickChatPlacementTests -only-testing:PetMacTests/QuickChatWindowTests -only-testing:PetMacTests/ChatPresentationTests -only-testing:PetMacTests/ChatActionWindowTests`。
- [ ] **4. 实现轻窗。** 独立可key窗口、非角色child，明确打开时取焦点；跟随角色/visibleFrame，失焦不抢回，尺寸仅本次运行保留、无自由拖走/位置保存。最近一轮及本轮正文以原生纯文字分句呈现，半句也可见，50ms既有流式合并仍用controller；不把分句当新历史。复用Task5卡片，终止/保存/保护/无连接有可达状态与完整窗入口；逻辑关闭/交接委托协调器。
- [ ] **5. 同命令GREEN并提交。** 验证真实输入控件而非镜像源字符串；缓存图片/合成事件不标物理输入或焦点通过；`git commit -m "feat: add anchored quick chat with shared conversation state"`。

## Task 7：生产菜单、全局门控与使用说明

**Files:** 改StatusBarController、AppDelegate、PetSession、ChatWindowController、HelpSettingsView、Info.plist、README、TODO；改`Tests/PetMacTests/ChatIntegrationTests.swift`，新`QuickChatIntegrationTests.swift`及工程。

**Interfaces:** StatusBar拥有唯一`chatPresentation:ChatPresentationCoordinator?`并注册完整与快速host；现有`chatWindow`引用可保留供兼容，但所有sheet/退出判断只问聚合所有者。新`openQuickChat()`入口；原openChat显示full。`PetSession.presentChatReply(_ text:String,showBubble:Bool = true)`仅让quick可见时抑制重复气泡，挥手仍用原条件，不改变其它反馈。协议桥由Controller持有并dispose；状态订阅不能覆盖FocusMenus.onChange或session.onStatusChange。

- [ ] **1. 写失败用例。** `testBothMenusOpenCorrectHostAndShareOneRequestGate`两套真实NSMenu入口、普通聊天与提炼/卡片单飞、隐藏桌宠时菜单可打开quick、换肤正确档案。`testEveryGlobalCommandSeesQuickModalAndTermination`逐个现有门控（快捷键/换肤/专注菜单/设置/帮助/诊断/退出）在quick模态拒绝，非模态继续原语义；退出仅调用一次Controller.beginTermination并等原已接受回执，取消退出不恢复卡。`testQuickReplySuppressesOnlyDuplicateBubble`原反馈可挥手、quick无额外摘要气泡、full沿旧逻辑，App整体隐藏时不以回复重新显示任何窗或气泡；安静/专注/隐藏条件维持，工具回执无普通反馈。
- [ ] **2. 运行RED。** `bash scripts/test.sh -only-testing:PetMacTests/QuickChatIntegrationTests -only-testing:PetMacTests/ChatIntegrationTests -only-testing:PetMacTests/QuickSkinMenuTests -only-testing:PetMacTests/FocusWindowTests`。
- [ ] **3. 实现生产接线。** 遍历现有chatWindow.hasBlockingSheet使用处统一替换聚合门控；完整与quick仅一个可见来源，真正关闭才取消。桥观察及host.dispose释放自身资源，不清别人的回调；原快捷键/皮肤/计时保存逻辑不绕过。两个窗口均按退出/取消退出同步按钮状态；App整体隐藏时抑制回复UI反馈，不能用orderFrontRegardless把隐藏App的气泡弹回。
- [ ] **4. 更新帮助与元数据。** 0.4.0/build26；说明4种操作、确认/取消、开始会保存常用时长、单轮一卡/状态过期、API发送范围/输入token增加、结果本地生成/失败只存盘、关闭与交接区别、轻窗跟随及隐藏独立；main schema13/v2保持。完整连接页同步发送范围，历史验收版本不改。TODO两项Minor只有对应RED/GREEN实际通过后勾选。
- [ ] **5. 同命令GREEN并提交。** 说明/版本变更后本次Green包含最终源码；`git commit -m "feat: integrate quick chat and scoped actions into app menus"`。

## Task 8：完整回归、一次整体评审与本地交付

**Files:** 新docs/quick-chat-actions-validation.md；更新README/TODO/AGENTS/设计计划状态。日志/探针/ledger备份仅忽略`.build/quick-chat-actions-validation/`，产物仅dist。必要修复才改对应源与测试。

- [ ] **1. 完整回归。** `bash scripts/test.sh`、`python3 -m unittest discover -s Tests/Release -v`，保存命令/退出码/实际总数和新类执行；基线400仅作对照，不能当新结果。原生须TEST SUCCEEDED、零失败，离线现有13项；保留任何失败。来源代码变化后重跑受影响用例及全原生，不重复无变化检查。
- [ ] **2. 优化同源隔离探针。** 假网络/凭据、三套原素材与临时配置，走流式→quick/full交接→proposal→真实计时/安静执行→回执存档/重开；卡片过期/ABA/双击、执行中同步关窗换角色、回执失败本地重试、已完成记忆候选共存、退出等待及输入/窗口边缘。浅深色/最小窗/长文/长错误/卡片滚动及原记忆草稿。记录生产source SHA/源码摘要/优化参数，若为构造探针需先ARM Release提供框架，则记Ruling，最终源变更必须重建/重跑受影响探针；不把探针写作分发二进制真实API通过。
- [ ] **3. 一次最终独立整体评审。** 已选Native，使用当时最强合适可用模型单一只读席位，审基线b154e6b至功能最终提交，携带本计划/spec/Review Focus/测试与探针证据。阻断项先回归复现再单轮修复，完整相关/原生/离线发版重新核验；Minor按实际影响记录或修复，说明判断和代价，不派第二次整体代码评审、不把额度失败算完成。
- [ ] **4. 干净来源双架构构建打包。** 功能/必要修复提交且tracked clean后顺序运行`bash scripts/build-app.sh arm64`、`bash scripts/build-app.sh x86_64`、两个架构`bash scripts/package-app.sh`；须实际BUILD SUCCEEDED、0.4.0/build26、14.0、单架构、同完整SHA/clean。评审前包仅最终SHA相同才复用。
- [ ] **5. 分发及附件。** 两App存在后`python3 -m unittest discover -s Tests/Distribution -v`（现有13项，据实际计数），检查签名/依赖/原素材/许可/库存/摘要及用户资料排除；本次8附件置专用空目录，`python3 scripts/prepare-release.py --assets STAGING_DIR --version 0.4.0 --commit FULL_SHA --check-only`离线验证，不远端写入。
- [ ] **6. ARM离工程启动。** 从本次DMG复制到真正中文空格路径，弹出源DMG后`python3 scripts/smoke-app.py --app MOVED_APP --check-restore --output .build/quick-chat-actions-validation/moved-smoke.json`。工具隔离配置、不继承开发环境；验证可见动画/正常退出/重开，不称外机/Gatekeeper/Intel或真实快捷输入通过。
- [ ] **7. 更新日用App。** 按准确路径正常退出Applications旧App并等接受写入，若未解决失败不得强杀；备份旧包、退出后主配置与AI文件（只盲复制/摘要，不解析私人AI或读Keychain），替换ARM、核对来源库存/版本/PID/自身窗口与schema13、偏好/皮肤/位置/快捷键/专注/统计和AI文件保留；不自动发API或改登录项。
- [ ] **8. 文档归档和本地交付。** 验证文档报告真实命令/数量/退出码、单次评审/修复/取舍、包与安装来源、备份及未测；更新TODO/AGENTS/本计划状态、本地提交。仅归档并移除此计划SDD workspace，保留其他ledger。交付ARM App/DMG绝对路径，用户验收重点为真实自然语言卡片与本地结果、quick/full流式切换、隐藏桌宠、实际IME/焦点；未做不标通过，保留现分支，不推送/打标签/Release。

## Plan Self-Review / 审核状态

主执行者已自审而未另派计划评审：设计1/2/4/6节对应Task1–4，3节对应Task5–7，5节和存档兼容对应Task4及原FIFO，7/8节对应Task7/8；五项Review Focus已分配具体失败用例。逐项核对了新终态的全部switch、三个Controller初始化、FocusMenus独占onChange、Published先发通知、原selectPage/windowWillClose清编辑、副作用回调重入、原角色回执及两个UI聚合模态；无未定义的后续类型接口。

该计划保留用户已选本会话Native/原地/一次最终评审。当前等待用户审核计划是否符合预期，通过后才按executing-plans逐任务实施；不重新要求选择执行方式。本轮仅文档，不运行新增功能测试、改个人App或触碰私人AI/Keychain；本版push/tag/Release仍无授权。
