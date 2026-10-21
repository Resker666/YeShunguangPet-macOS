# 0.1.12 Updates, Shortcuts and Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付具有手动检查公开更新、三个可配置全局快捷键和五组设置的本地0.1.12 App，保留原有皮肤与个人偏好。

**Architecture:** PetCore提供更新数据校验、快捷键值类型和schema8迁移；App侧分别拥有有界URLSession请求与主线程Carbon登记控制器，调用既有PetSession命令。设置复用一个窗口和原皮肤事务模型，通过五个Tab显示功能；A、B先形成可单独测试的组件，C统一接入，保持一份交付计划。

**Tech Stack:** Swift 6、AppKit、SwiftUI、Foundation URLSession、公开Carbon/HIToolbox、XCTest、现有Python/构建脚本；不增加外部依赖。

**Spec:** [已批准的0.1.12设计](../specs/2026-10-21-macos-update-shortcuts-settings-design.md)。用户已选择本会话直接实施，复用独立Mac仓库，不创建额外工作树。本计划已获用户“开始执行”批准。

## Global Constraints

- Swift 6、AppKit、SwiftUI、macOS 15+；arm64日用，x86_64实验交叉构建。
- Windows和Minimal Sleep继续只读，皮肤JSON/PNG保持原字节；不新增第三方运行库、登录服务或收费签名依赖。
- 只做本地提交；本版推送、标签、Release草稿和公开发布均另等明确指令。
- 只有用户手动操作才检查更新；固定匿名GET `https://api.github.com/repos/Resker666/YeShunguangPet-macOS/releases/latest`，不读取Token或Git配置。
- 临时URLSession，禁用持久缓存和Cookie；请求超时15秒、资源总超时20秒，响应体最多1 MiB，实际接收也受限；更新说明纯文本最多8000字符。
- 三个快捷键默认均不绑定；至少两个修饰键且含Control或Option，按键为常用字母、数字与F1–F12的美式物理键位；编辑采用勾选/选择后应用，不做录制器。
- Carbon登记使用kEventHotKeyExclusive且统一在主线程；菜单、模态sheet、退出期间抑制命令，普通设置打开不抑制。
- schema8读取schema1–7并默认空快捷键；v8非法/缺字段保护原文件，保存仍为64 KiB上限和原子替换。
- 测试配置和素材目录隔离，不改正式个人快捷键或登录项；外机、Intel、真实按键/焦点/睡眠/Spaces与Gatekeeper首开分别记录，不从模拟或交叉构建推定。

## Review Focus

1. 公开版本高于、等于或低于当前版本，以及合法版本但缺本机DMG，应分别显示准确结果；任务1与5的比较/菜单整合测试负责。
2. 伪造Content-Length、跨站重定向，以及取消后才返回的结果，不能绕过实际大小限制或覆盖新查询；任务2的传输与代次测试负责。
3. 新绑定登记后保存失败，随后恢复旧登记或撤销候选再次失败，必须显示真实系统状态并保持原偏好；任务4的两资源失败测试负责。
4. 菜单期间开始按住、关闭菜单后自动重复，以及旧登记的排队事件，不得多次或延迟执行角色命令；任务4的按下/松开与旧ID测试负责。
5. 从任意设置组拖入后切页/关窗、删除确认sheet和退出取消，不能误导入或重复登记登录项/快捷键；任务5的原生整合测试负责。

## File Structure

| 文件 | 责任 |
| --- | --- |
| `Sources/PetCore/Updates/ReleaseInfo.swift` | 版本、架构、Release解析、可信链接及版本关系 |
| `Sources/PetCore/Shortcuts/KeyboardShortcuts.swift` | 动作、修饰键/物理键码、绑定与组合唯一性校验 |
| `Sources/PetCore/Persistence/SettingsStore.swift` | PetPreferences新增字段、旧schema迁移和严格v8 |
| `Sources/YeShunguangPet/Updates/{ReleaseUpdateClient,ReleaseUpdateModel}.swift` | 有界临时网络传输、手动查询状态和取消 |
| `Sources/YeShunguangPet/Shortcuts/{CarbonHotKeyRegistry,ShortcutController}.swift` | 系统资源生命周期、事务恢复、命令路由和可观察登记结果 |
| `Sources/YeShunguangPet/Settings/SettingsModel.swift` | 从原控制器文件移出的既有共享模型，不复制皮肤事务 |
| `Sources/YeShunguangPet/Settings/{SettingsTabsView,SkinSettingsView,GeneralSettingsView,InteractionSettingsView,ShortcutSettingsView,AboutSettingsView}.swift` | 五个分组及共用保存错误/拖入高亮 |
| `Sources/YeShunguangPet/{SettingsWindowController,StatusBarController,AppDelegate,PetSession}.swift` | 窗口协调、菜单入口、加载后启动服务、事务保存边界与退出 |
| `YeShunguangPet.xcodeproj/project.pbxproj` | 新源码与用例登记到Core/App/两个测试target，维护单份生产源码 |
| `Tests/PetCoreTests/{ReleaseInfoTests,KeyboardShortcutsTests,SettingsStoreTests}.swift` | 更新纯逻辑、绑定校验、配置兼容/保护 |
| `Tests/PetMacTests/{ReleaseUpdateTests,ShortcutControllerTests,CarbonHotKeyRegistryTests,SettingsGroupsTests}.swift` | 传输/取消、登记失败恢复、原生适配和设置整合 |
| `Tests/PetMacTests/{SkinSelectionTests,PetSessionTests,LoginItemTests}.swift`、`Tests/Distribution/test_settings.py` | 保留原回归并补新接口/当前schema断言 |
| `Sources/YeShunguangPet/Info.plist`、`README.md`、`AGENTS.md`、`TODO.md`、`docs/release-notes/0.1.12.md`、`docs/update-shortcuts-settings-validation.md` | 0.1.12/build13、使用方式、发版说明和真实验证边界 |

所有新增文件随所属任务登记工程。任务日志保存在本计划独有的忽略工作区，最终需长期保存的验证摘要另存`.build/update-shortcuts-settings-validation/`及验证文档。每次提交前`git diff --check`；环境/工程错误与需求断言失败分别记录。

### Task 1: 公开更新数据和可信下载入口

**Files:** 创建`ReleaseInfo.swift`、`ReleaseInfoTests.swift`，修改工程Core/CoreTests源文件登记。

**Interfaces:**
- 产生`ReleaseVersion: Comparable, Equatable, Sendable`，`init?(tag: String)`接受可选v前缀及三个ASCII十进制UInt32分量；`description: String`用于显示数值版本。
- 产生`ReleaseArchitecture: String, Sendable`（`arm64`、`x86_64`）、`ReleaseComparison`（`newer`、`current`、`ahead`）。
- 产生`ReleaseInfo: Equatable, Sendable`，含`version: ReleaseVersion`、`tag: String`、`pageURL: URL`、`notes: String`、`downloadURL: URL?`；`static parse(_ data: Data, architecture: ReleaseArchitecture) throws -> ReleaseInfo`和`comparison(to current: ReleaseVersion) -> ReleaseComparison`。

- [x] **Step 1: 写失败用例。** `testNumericVersionOrderAndDevelopmentAhead`精确断言：
  ```swift
  XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion(tag:"v0.1.10")), try XCTUnwrap(ReleaseVersion(tag:"0.1.9")))
  XCTAssertEqual(try info(tag:"v0.1.9").comparison(to:XCTUnwrap(ReleaseVersion(tag:"0.1.12"))), .ahead)
  XCTAssertNil(ReleaseVersion(tag:"v0.1.12-beta"))
  XCTAssertNil(ReleaseVersion(tag:"4294967296.1.0"))
  ```
  用本测试文件中的`info(tag:)`构造官方JSON并调用真实parse。`testStableOfficialLinksAndMissingArchitecture`断言完整ARM附件被接受、只有Intel时ARM的downloadURL为nil且pageURL保留；说明8001字符截为8000。`testUntrustedAndNonPublicReleasesAreRejected`覆盖draft/prerelease、坏JSON、缺字段、外站/凭据/端口/query/fragment、不同仓库/tag/附件名与路径不匹配。
- [x] **Step 2: 验证RED。** `bash scripts/test.sh -only-testing:PetCoreTests/ReleaseInfoTests`。Expected: 新类型缺失；登记完成后须能进入测试，不把工程配置错误当功能RED。
- [x] **Step 3: 实现接口。** 数值比较不用字符串顺序；保留原tag用于精确路径验证。只接受本仓库HTTPS发布页及`YeShunguangPet-<tag去v>-macOS-<架构>.dmg`官方Release附件路径。坏附件不变成可点的URL，缺附件不阻止可信发布页；说明只作String纯文本。
- [x] **Step 4: 验证GREEN。** 同Step 2命令。Expected: 本类全部通过，包括newer/current/ahead三种断言及版本边界0、UInt32.max、非法段数/Unicode数字/负号。
- [x] **Step 5: 本地提交。** 暂存本任务精确文件，提交`feat: validate public release versions and download links`。

### Task 2: 有界手动更新查询与取消

**Files:** 创建`ReleaseUpdateClient.swift`、`ReleaseUpdateModel.swift`、`ReleaseUpdateTests.swift`；修改工程App/MacTests登记。

**Interfaces:**
- 消费任务1`ReleaseInfo.parse(_:architecture:)`和`comparison(to:)`。
- 网络边界`ReleaseFetching: Sendable`：`func fetchLatest(architecture: ReleaseArchitecture) async throws -> ReleaseInfo`；`ReleaseUpdateClient`为生产实现，允许测试注入URLSessionConfiguration的URLProtocol，仅生产固定官方endpoint。
- `@MainActor ReleaseUpdateModel: ObservableObject`：`init(currentVersion: ReleaseVersion, architecture: ReleaseArchitecture, client: any ReleaseFetching)`；`state: ReleaseUpdateState`只读发布，状态为idle/checking/success(info,comparison)/failure(message)；`check()`去重，`cancel()`取消并使旧代次失效。

- [x] **Step 1: 写失败用例。** `testManualOnlyDedupAndStaleCompletion`用可控异步传输替身断言初始化请求计数0、两次check仅1、cancel后重试变2，先完成新请求再送旧成功/失败都不覆盖新state。`testBoundedTransportAndRedirects`用URLProtocol喂真实客户端：声明1048577直接拒绝；声明缺失/较小但实际1048577仍拒绝；合法JSON补空白至1048576接受；302跨站不跟随。`testTransportContractAndFailures`检查GET/固定URL、Accept和API头、无Authorization/Cookie、15/20秒及无持久缓存；覆盖200坏JSON、403/429限流、404无公开版本、500、超时、断网、取消与非HTTP响应。
- [x] **Step 2: 验证RED。** `bash scripts/test.sh -only-testing:PetMacTests/ReleaseUpdateTests`。Expected: 新客户端/模型缺失；替身须能完成各请求，不依赖真实网络或睡眠延时。
- [x] **Step 3: 实现传输。** 临时session禁用cookie/cache，使用官方Accept与`X-GitHub-Api-Version: 2026-03-10`；固定canonical URL，不跟随重定向。逐块或AsyncBytes累计接收前检查1048576上限，超限立即取消，不能先`data(for:)`完整分配后才检查。取消向底层task传播，资源在请求完成后释放。
- [x] **Step 4: 实现模型并验证GREEN。** 单独持有Task和代次；关闭/退出可同步使旧回调失效，正常打开/切页不查询。运行Step 2命令及任务1测试。Expected: 全通过，无测试访问公网。
- [x] **Step 5: 本地提交。** 提交`feat: add bounded manual release checks with cancellation`。

### Task 3: 快捷键值类型与schema8兼容

**Files:** 创建`KeyboardShortcuts.swift`、`KeyboardShortcutsTests.swift`；修改`SettingsStore.swift`、`SettingsStoreTests.swift`和工程登记。

**Interfaces:**
- `ShortcutAction: String, Codable, CaseIterable, Sendable`：`toggleVisibility`、`recall`、`toggleQuiet`。
- `ShortcutModifiers: OptionSet, Codable, Hashable, Sendable`，rawValue为UInt32；内部位command=1、option=2、control=4、shift=8，禁止未知位。
- `ShortcutCombination: Codable, Hashable, Sendable`，`init(keyCode: UInt32, modifiers: ShortcutModifiers)`；`isValid: Bool`按允许键码和修饰键规则验证；物理键码对应当前SDK的A–Z、0–9、F1–F12，不把范围中所有数字都当合法键。
- `ShortcutBinding: Codable, Equatable, Sendable`，`action`与`combination`；`KeyboardShortcuts.validate(_ bindings: [ShortcutBinding]) throws`拒绝重复动作/组合及无效项。`PetPreferences.keyboardShortcuts: [ShortcutBinding]`默认`[]`。

- [x] **Step 1: 写失败用例。** `testDefaultAndModifierKeyContract`断言默认空、Control+Option+A(keyCode0)合法、Command+Shift+A/单Control/未知位/非白名单键码非法。`testDuplicateActionsAndCombinationsRejected`覆盖相同动作不同键、不同动作同键、三项合法往返。新增`testVersionsOneThroughSevenMigrateWithEmptyShortcuts`逐份旧schema夹具断言原位置/UUID及该版本已支持偏好完整保留、快捷键为空，保存schema8后再次读取相等。`testInvalidVersionEightProtectsOriginalBytes`覆盖缺字段/未知动作/类型错误/重复/非法键码及修饰位，断言save抛错、原字节不变。
- [x] **Step 2: 验证RED。** `bash scripts/test.sh -only-testing:PetCoreTests/KeyboardShortcutsTests -only-testing:PetCoreTests/SettingsStoreTests`。Expected: 新类型/字段缺失或保存版本仍为7的明确失败。
- [x] **Step 3: 实现模型与迁移。** v7使用专用旧偏好结构而非给v8解码字段静默补默认；v8必须包含keyboardShortcuts数组。沿用StrictJSON、65536字节实际读取、保护和原子写入；PetPreferences.isValid纳入完整绑定校验。
- [x] **Step 4: 验证GREEN。** 更新旧用例中“本版保存版本”断言为8，旧输入版本夹具继续保留。运行Step 2命令并补`testVersionEightRoundTripAndSixtyFourKiBBoundary`，断言合法空/三项绑定都可往返、65536合法/65537保护。
- [x] **Step 5: 本地提交。** 提交`feat: migrate settings to validated optional keyboard shortcuts`。

### Task 4: 系统登记、事务恢复与角色命令

**Files:** 创建`CarbonHotKeyRegistry.swift`、`ShortcutController.swift`、`ShortcutControllerTests.swift`、`CarbonHotKeyRegistryTests.swift`；修改`PetSession.swift`、`PetSessionTests.swift`及工程登记。

**Interfaces:**
- 消费任务3模型。`PetSession.saveKeyboardShortcuts(_ bindings: [ShortcutBinding]) throws`先保存完整候选配置，成功才更新运行偏好；失败保留旧快捷键并发布persistenceError。普通`setPreferences`拒绝绕过该入口修改快捷键。
- `@MainActor HotKeyRegistry: AnyObject`仅替换OS边界：`onEvent: ((UInt32, Bool) -> Void)?`（id、是否按下），`register(_ combination: ShortcutCombination, id: UInt32) throws`、`unregister(id: UInt32) throws`、`dispose() throws`。生产`CarbonHotKeyRegistry`检查每个OSStatus，失败不假装释放。
- `@MainActor ShortcutController: ObservableObject`：`init(session: PetSession, registry: any HotKeyRegistry, canDispatch: @escaping () -> Bool)`；`start()`只登记一次，`apply(_ combination: ShortcutCombination?, to action: ShortcutAction)`、`retry(_ action: ShortcutAction)`、`dispose()`。每动作发布`ShortcutStatus`，含`remembered`、`active`组合、`pendingCleanup`组合列表与`message`；pendingCleanup表示未保存但尚未成功撤销的系统占用，不可执行命令。

- [x] **Step 1: 写失败用例。** 用登记器替身驱动真实控制器与临时SettingsStore。`testReplaceConflictLeavesOldRegistrationAndFile`断言系统拒绝候选后旧活动键、偏好、文件逐字节不变。`testSaveFailureRestoresOldOrReportsInactive`注入磁盘失败，分别让旧登记恢复成功/失败，断言旧偏好未变，active为旧值/nil并有明确错误；`testUnregisterFailureRetainsActualOccupancyAndCanRetry`断言pendingCleanup可见且不能触发。`testStartupConflictClearProtectedResetAndDispose`覆盖一个冲突不影响另两个、相同绑定重试、清除成功/保存失败、受保护不变更及dispose后事件无效。
- [x] **Step 2: 写输入生命周期断言并验证RED。** `testHeldSuppressedAndStaleEventsDoNotToggle`按同ID发送down/down/up/down，断言仅两次切换；菜单抑制时down、解除抑制后重复down不触发，须up后新down才触发；替换前ID、未知ID、dispose后事件均不触发。`testCommandsUseSessionAndNormalSettingsAllowDispatch`断言隐藏→召回显示、quiet只改会话状态、模态sheet抑制与普通设置允许。运行`bash scripts/test.sh -only-testing:PetMacTests/ShortcutControllerTests -only-testing:PetMacTests/PetSessionTests`。Expected: 新接口缺失或旧保存边界失败。
- [x] **Step 3: 实现会话保存与登记事务。** 候选先登记，旧释放成功后才保存；保存失败撤候选、恢复旧，逐项检查并展示真实active/pendingCleanup。清除也有同等恢复。只允许已提交有效ID执行；ID单调递增不复用，释放时清理按住状态。受保护/退出时拒绝变更；同组合已活动不重复登记，记住但未活动允许重试。
- [x] **Step 4: 实现Carbon适配及其原生测试。** 安装pressed/released事件处理器、独占登记、主线程回调及修饰位转换；系统移除处理器后才释放回调上下文，移除失败保留安全上下文并报告。`testExclusiveRegistrationConflictAndRelease`实际登记独立测试组合、第二登记器独占冲突、释放后重试成功；保留独立测试Bundle与组合，任何提前失败也defer释放。该测试只证明API登记/冲突/撤销，不证明物理全局按键。
- [x] **Step 5: 验证GREEN并提交。** `bash scripts/test.sh -only-testing:PetCoreTests/KeyboardShortcutsTests -only-testing:PetMacTests/ShortcutControllerTests -only-testing:PetMacTests/CarbonHotKeyRegistryTests -only-testing:PetMacTests/PetSessionTests`。Expected: 全部通过，失败恢复用例文件不变、无遗留测试登记。提交`feat: add transactional global shortcuts for pet commands`。

### Task 5: 五组设置、菜单入口与服务生命周期

**Files:** 创建上述`Settings/`分组文件与`SettingsGroupsTests.swift`；修改`SettingsWindowController.swift`、`StatusBarController.swift`、`AppDelegate.swift`、`SkinSelectionTests.swift`、`LoginItemTests.swift`、工程登记；版本改为0.1.12/build13。

**Interfaces:**
- 消费任务2`ReleaseUpdateModel`、任务4`ShortcutController`；由StatusBarController持有两者并注入窗口，不在SwiftUI视图重建时创建服务。
- `SettingsTab: String, CaseIterable`：`skin`、`general`、`interaction`、`shortcuts`、`about`；SettingsModel发布`selectedTab`，默认skin且不持久化。
- `SettingsWindowController.init(session: PetSession, updates: ReleaseUpdateModel, shortcuts: ShortcutController, loginItem: LoginItemController? = nil)`；`present(tab: SettingsTab? = nil)`、`hasBlockingSheet: Bool`，保留`acceptSkinDrop(from:)`和原退出等待接口。`ShortcutSettingsView`编辑态切页/关窗重置为已应用值；更新结果和皮肤candidate不因切页丢失。
- `StatusBarController.startShortcuts()`由AppDelegate在session.start后调用；`beginTermination()`取消查询并抑制命令，`cancelTermination()`恢复允许调度但不自动查询，`dispose()`释放两服务。新增`checkUpdatesItem`进入about再check；原openSettings只present。

- [ ] **Step 1: 写失败用例。** `testFiveGroupsAndManualUpdateMenuOnly`断言五个tab顺序、首次skin、普通打开/刷新/切页/会话状态变化均请求0次，菜单检查进入about且请求1次。`testTabReopenAndDropFromEveryGroup`逐组使用原生Pasteboard拖入同一合成ZIP，断言转skin、candidate有值但库未安装，切页candidate仍在，close清空且重开无隐式导入。`testModalAndTerminationGatesDoNotRecreateServices`断言sheet拒收拖入及热键命令，开始退出取消查询、取消退出能继续使用，所有刷新不增加登记/登录注册次数。
- [ ] **Step 2: 验证RED。** `bash scripts/test.sh -only-testing:PetMacTests/SettingsGroupsTests -only-testing:PetMacTests/SkinSelectionTests -only-testing:PetMacTests/LoginItemTests`。Expected: 新tab/窗口依赖接口未提供。为既有原生测试提供共享的无网络/隔离登记器工厂，不能以默认生产服务掩盖测试外部副作用。
- [ ] **Step 3: 移动模型并组装界面。** 单份皮肤模型保留任务/代次/确认/关闭清理；TabView各Form独立滚动，窗口仍正常key/main，共用保存错误与整窗拖入高亮。任意页成功接收支持文件时转skin再走共享预览。通用与互动保留原控件、范围、提示和登录项真源。快捷键明确美式物理键位、应用/清除/重试及实际状态；about显示当前版本/架构、三种版本关系、纯文本说明和缺附件提示。
- [ ] **Step 4: 接入菜单/生命周期并验证GREEN。** 浏览器只在点击时通过NSWorkspace.open打开任务1已验证的URL；启动不查询、偏好加载后才注册，普通刷新不注册。窗口关闭取消查询/编辑，退出取消和真正退出资源释放分别处理。运行Step 2命令及`bash scripts/test.sh -only-testing:PetMacTests/ReleaseUpdateTests -only-testing:PetMacTests/ShortcutControllerTests`。Expected: 全部通过且原ZIP/文件夹/JSON导入、退出等待回归保留。
- [ ] **Step 5: 本地提交。** 提交`feat: group settings and expose manual updates and shortcuts`。

### Task 6: 回归、原生探针与交付说明

**Files:** 修改`Tests/Distribution/test_settings.py`当前保存版本断言、`README.md`、`AGENTS.md`、`TODO.md`；创建`docs/release-notes/0.1.12.md`和`docs/update-shortcuts-settings-validation.md`；探针/日志保留在忽略验证目录。

**Interfaces:** 消费任务1–5的完整App与既有build/package/smoke脚本；不改变CI权限或触发Release草稿。验证文档区分自动化、本机API/进程、用户操作和外机证据。

- [ ] **Step 1: 写分发回归断言并验证RED。** 在`test_settings.py`旧配置搬移用例断言重开为schema8、keyboardShortcuts为[]且原缩放/置顶/位置保留；该用例后半段用于重开的完整preferences字典也加入keyboardShortcuts空数组，避免生成缺字段的非法v8。确认`dist/YeShunguangPet.app`仍为0.1.11后运行`python3 -m unittest discover -s Tests/Distribution -p test_settings.py -k legacy_position -v`，Expected: 保存7与预期8不符；再构建新版验证，不把不存在的产物当RED。若产物已被新版替换，先在本计划忽略目录复制保留的0.1.11和同一测试/脚本布局，执行相同用例，不回退源码或个人App。
- [ ] **Step 2: 运行完整检查。** 依次`bash scripts/test.sh`、`python3 -m unittest discover -s Tests/Release -v`、`bash scripts/build-app.sh arm64`、`bash scripts/build-app.sh x86_64`、`python3 -m unittest discover -s Tests/Distribution -v`、`python3 scripts/smoke-app.py`。Expected: 原生全部通过、13项发版离线和10项分发通过，两个架构构建成功；如现有数量变化，逐项说明新增/删改原因。
- [ ] **Step 3: 做隔离原生探针并查看渲染。** 独立Bundle/临时配置实际匿名GET一次，记录时间/HTTP结果/当前公开版本与比较；断网/限流仅据实际结果报告，不把离线替身记公网成功。独立组合验证Carbon独占登记/释放。渲染并查看五组PNG，覆盖皮肤candidate、8000字符说明、长错误、恢复失败状态及小窗口滚动；测试不调用正式SMAppService登记/撤销。
- [ ] **Step 4: 写使用与验证文档。** 写默认不绑定、如何应用/清除/重试、菜单手动检查、官方浏览器下载、未公证安装说明及schema兼容；TODO保留真实跨应用按键、焦点/睡眠/Spaces、重新登录、Intel/外机和云端草稿待验证。文档先记录已发生的结果，后续交付后再补最终包/安装证据，不能预填通过。
- [ ] **Step 5: 本地提交并完成任务验证。** `git diff --check`与Step 2的全套检查均有新结果后提交`test: verify update shortcuts and grouped settings delivery`。完成记录引用日志和准确来源，不重复无变化的全套测试。

## 全分支评审后完成本地交付

六项任务连续实施，不逐项请求继续。按executing-plans记录任务BASE、RED/GREEN、接口核对和必要Ruling；任务完成后使用requesting-code-review派出一次只读独立评审，覆盖整个分支、设计、计划、Review Focus和Ruling。按实际影响处理Critical/Important并以失败回归→修复→完整原生/受影响检查证明；Minor如不处理明确记录。此阶段不合并main或推送。

- [ ] 评审及必要修复完成并提交后，从明确干净来源导出构建目录，先确认两架构build-info均指向同一来源且`trackedChanges=false`；导出目录内现有脚本会向父目录查询Git，因此双架构构建期间父仓库HEAD及跟踪文件保持不变，逐一核对输出commit。依次构建/打包ARM和Intel，运行`bash scripts/package-app.sh arm64`及`bash scripts/package-app.sh x86_64`，检查八份版本/架构命名附件、SHA-256、DMG挂载、ZIP内容、ad-hoc签名、最低系统与原素材哈希，保留ARM搬移/重开证据。此为本机验证，不称Intel运行或Gatekeeper首开通过。
- [ ] 升级日用App前按准确可执行路径识别并正常退出旧进程，备份旧App与当时个人配置；不复制旧PID操作其他进程。安装`/Applications/YeShunguangPet.app`后正常启动，核对0.1.12/build13及schema7→8偏好、UUID和更新时位置保留、快捷键为空；不自动开启登录项、不触发查询。失败使用备份恢复并报告真实结果。
- [ ] 将最终来源、测试数、包摘要、渲染/API边界、个人App迁移和未验证项目写入验证文档；本地提交文档，保持构建产物仍指向已核实的实现提交。按finishing-a-development-branch保留该开发分支，交付ARM App/DMG链接与简短体验步骤，不再询问已确定的实施方式，不自行推送/打标签/创建草稿/发布。

## 计划自检

已逐段核对已批准设计：A由任务1/2/5覆盖，B由3/4/5覆盖，C由5覆盖；保护/迁移、真实API、原流程回归、评审和本地交付由3/6及末段覆盖。接口名称和调用顺序已交叉核对，五项Review Focus均有归属用例；没有额外子项目或未决占位符。实施方式沿用本会话直接开发，书面计划评审后连续执行。
