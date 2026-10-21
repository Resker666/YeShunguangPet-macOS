# 自定义台词与专注计时 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付0.1.15的个人台词和手动衔接专注/休息计时，更新本机ARM日用App。

**Architecture:** PetCore持有四类台词验证及纯FocusTimer；PetSession负责持久化提交和角色暂停/回应，FocusController独立持有单次期限调度。六个设置Tab及两个原生菜单共享一个Controller，不随设置窗口关闭而结束。

**Tech Stack:** Swift 6、AppKit、SwiftUI、XCTest，现有Xcode，无新增依赖。

**Spec:** `docs/superpowers/specs/2026-10-21-macos-focus-custom-speech-design.md`

用户明确“设计好，你就执行，我睡觉了”，已授权自审后直接本会话实施，不再等待逐阶段审批。沿用原地独立Mac仓库开发；推送、标签和Release未获本版授权。

## Global Constraints

- macOS 15+，arm64日用、x86_64实验交叉构建；0.1.15/build16。
- 专注25、休息5，范围分别1–120及1–60整数分钟；只手动衔接，退出不恢复运行段。
- ContinuousClock计入睡眠；计时不依赖角色可见/设置打开；不用墙钟，不逐秒保存。
- 个人台词按manifest.id，最多16角色、每类8句、每句80 UTF-16、总8192 UTF-16；配置64KiB。
- schema10严格读取新字段，1–9专用迁移；失败保护原字节；新台词/时长必须先保存再生效。
- 显示台词默认关闭；普通30秒冷却、6秒气泡，完成事件可越过普通冷却但仍受显示开关与交互门控。
- 无系统通知、声音、历史、联网、额外悬浮窗、防睡眠或自动循环；JSON/PNG不改，Windows/Minimal Sleep只读。
- 测试同时隔离配置和素材；不得更改正式登录项或用合成事件声称物理/系统/Intel/外机通过。

## Review Focus

1. 倒计时到期与暂停/旧开始同刻：只能完成旧阶段，不因一个过期按钮命令启动下一段；Task 1与2锁定。
2. 专注结束或暂停不取消用户原先的手动安静；换肤、隐藏、锁定不能中断计时；Task 2锁定。
3. 旧schema9完整保留快捷键、贴边、锁定、UUID和位置；schema10缺台词/时长字段不能默默默认；Task 1锁定。
4. 编辑角色A后切到B、切页或关窗，旧草稿不能保存到B；保存失败旧台词仍有效；Task 2与3锁定。
5. 隐藏/关设置后没有每秒刷新、无重复期限Timer；取消退出按原期限结算一次、完成时菜单跟踪不抢焦点；Task 2与3锁定。

## Files and responsibilities

| 文件 | 职责 |
| --- | --- |
| `Sources/PetCore/Runtime/PersonalSpeech.swift` | 覆盖验证及文本草稿解析 |
| `Sources/PetCore/Runtime/FocusTimer.swift` | 纯状态/期限，无系统对象 |
| `Sources/PetCore/Runtime/Speech.swift`、`Skin/PetManifest.swift` | 四类事件、公共台词值、默认文案和选择 |
| `Sources/PetCore/Persistence/SettingsStore.swift` | schema10、专用v9迁移及新字段 |
| `Sources/YeShunguangPet/FocusController.swift` | 共享可观察计时及独立FrameScheduler |
| `Sources/YeShunguangPet/PetSession+Companion.swift`、`PetSession.swift` | 专用偏好提交、临时暂停与完成回应；不扩张原会话杂项职责 |
| `Sources/YeShunguangPet/FocusMenus.swift` | 双子菜单命令与状态 |
| `Sources/YeShunguangPet/Settings/{FocusSettingsView,PersonalSpeechEditor}.swift` | 专注与个人台词界面 |
| `StatusBarController.swift`、设置模型/窗口/Tab | 共享对象及可见性/菜单跟踪/退出桥接 |
| `Tests/PetCoreTests/{FocusTimerTests,PersonalSpeechTests,CompanionSettingsTests}.swift` | 纯状态、覆盖及迁移 |
| `Tests/PetMacTests/FocusCompanionTests.swift` | 原生提交、门控、菜单/设置与调度 |

### Task 1: 纯状态、台词解析与可迁移配置

**Interfaces:**
- `SpeechEvent:String,CaseIterable,Sendable`提供click/drag/focusCompleted/breakCompleted；`SpeechLines:Codable,Equatable,Sendable`有公共四数组初始化、`defaults`及`lines(for:)`。
- `PersonalSpeech.validate(_ overrides:[String:SpeechLines]) throws`、`PersonalSpeech.parse(_ text:String) throws -> [String]`、`PersonalSpeech.resolve(id:String,skin:SpeechLines?,overrides:[String:SpeechLines])->SpeechLines`。
- `PetPreferences`新增focusMinutes、breakMinutes及speechOverrides，默认25、5、[:]；保留全部已有字段。
- `FocusPhase`为focus/rest；`FocusStatus`为ready/running/paused/completed。`FocusTimer`提供phase/status、`remaining(at:Duration)->Duration`、`deadline:Duration?`、`configure(focusMinutes:Int,breakMinutes:Int)throws`、`startOrResume(at:Duration)->FocusPhase?`、`pause(at:Duration)->FocusPhase?`、`advance(at:Duration)->FocusPhase?`、`reset()`。所有完成返回只出现一次，开始时发现原running已过期只能返回完成，不能启动下一段。

- [ ] Step 1: 添加并注册三套Core测试。先用现有SettingsStore写入schema10新字段，再读取必须失败（当前旧实现）；添加纯状态/台词API测试，产品类型尚无时分别记录编译缺失，不混称断言RED。
  - `testVersionNineMigrationPreservesAllPreferencesPlacementAndSelection`断言旧字段不变、新25/5/[:]及保存为10。
  - `testVersionTenMissingAndInvalidNewFieldsRemainByteIdentical`覆盖三个字段缺失、0/121/61/true、非法ID/控制字符/超限。
  - `testManualPhasesPauseLateCompletionAndStaleCommands`断言1分钟段在59秒暂停、100秒继续后101秒完成仅一次；旧开始不能启动休息；下一次显式开始才进入rest。
  - `testSpeechPrecedenceExplicitEmptyLimitsAndCompletionCooldown`断言四类默认、个人覆盖、空数组、emoji计数/16角色/8192总量及普通30秒与完成事件区别。
- [ ] Step 2: 运行`bash scripts/test.sh -only-testing:PetCoreTests`到忽略目录，核对RED原因。
- [ ] Step 3: 实现上述API。提取ManifestDecoder共用的合法ID判断，不放宽原皮肤校验。为schema9增加旧结构，新schema10必须有三个新字段。现有迁移断言的写出版本更新为10，原v9无效字段用真实v9结构验证，不让缺新字段掩盖原测试目标。
- [ ] Step 4: 同命令验证GREEN，检查新配置容量、所有旧Core回归；`git diff --check`。
- [ ] Step 5: 提交`feat: add personal speech and manual focus timer models`，task-done运行完整`bash scripts/test.sh`，读结果并记入本计划ledger。

### Task 2: 共享计时、角色暂停和安全提交

**Consumes:** Task 1全部公开API、现有PetSession.now和FrameScheduler。

**Produces:**
- `PetSession.saveSpeechOverrides(_ overrides:[String:SpeechLines]) throws`、`saveFocusDurations(focusMinutes:Int,breakMinutes:Int)throws`，先存储候选再生效；普通setPreferences拒绝改新字段。
- `PetSession.setFocusQuiet(_ enabled:Bool)`、`presentFocusCompletion(_ phase:FocusPhase)`；手动isQuiet不变，被动逻辑使用`isQuiet || focusQuiet`。
- `FocusController(session:PetSession)`有可观察phase/status/remainingSeconds、`startOrResume()`、`pause()`、`reset()`、`refreshConfiguration()`、`applyDurations(focusMinutes:Int,breakMinutes:Int)throws`、`setDisplayVisible(_:Bool,source:String)`、`setSleeping(_:Bool)`、`setTerminating(_:Bool)`、`refreshTime()`、`dispose()`及onChange回调。idle/paused/completed无调度，运行且无可见消费者仅截止一个调度。

- [ ] Step 1: 写并注册FocusCompanionTests，先在原生对象上复现专注不抑制/新提交未生效；缺API分别标编译RED。覆盖独立时钟隐藏继续、重复/晚到到期、手动安静原值、锁定/换肤/快捷键保留、保存失败、普通setPreferences不能绕过、终止取消及显示消费者销毁。
- [ ] Step 2: 运行`bash scripts/test.sh -only-testing:PetMacTests/FocusCompanionTests`核对RED。
- [ ] Step 3: 实现Controller与Session桥接。Controller由Status持有并在session.start之后同步配置；FrameScheduler单独实例只负责计时。状态/展示回调不能每秒调用全量SettingsModel.refresh。机器睡眠/退出取消唤醒，唤醒/取消退出一次结算；真实睡眠仍不由这些注入测试宣称。
- [ ] Step 4: 同命令GREEN；增加四类气泡的实际被动窗口验证，确定普通冷却不吞完成台词、被挡完成不补播。
- [ ] Step 5: 提交`feat: run focus sessions independently of pet visibility`，task-done完整`bash scripts/test.sh`。

### Task 3: 专注菜单、设置与个人台词编辑

**Consumes:** Task 2共享Controller及新提交方法；沿用SettingsModel共享、QuickSkinMenus与现有模态/退出判断。

**Produces:** 两个独立FocusMenus子菜单；新增SettingsTab.focus；PersonalSpeechEditor捕获当前manifest ID和编辑代次，关闭/切页/换肤丢弃未应用草稿。

- [ ] Step 1: 在FocusCompanionTests增加原生菜单和六Tab测试。断言两个子菜单不同对象、状态/按钮同步、父子菜单全部关闭才恢复、模态/退出拒收、关窗计时继续、设置未首开即可操作。保存草稿捕获ID：A→B旧草稿拒绝提交；关闭/切页编辑代次改变；失败仍使用旧覆盖。
- [ ] Step 2: 运行`bash scripts/test.sh -only-testing:PetMacTests/FocusCompanionTests`确认旧菜单/Tab及模型断言失败。
- [ ] Step 3: 实现FocusMenus、专注页、互动页个人台词编辑、SettingsModel编辑代次和管理已保存覆盖入口。只有活动专注页/跟踪菜单登记倒计时显示消费者，关窗/最小化/切页释放。按钮展示remaining按ceil秒，禁用非法时长与退出操作，应用失败保留草稿提示原因。
- [ ] Step 4: 更新版本0.1.15/build16、README、AGENTS、TODO、皮肤兼容矩阵及release-notes/0.1.15.md；写focus-speech-validation.md记录实际边界。目标测试GREEN、离线发版`python3 -m unittest discover -s Tests/Release -v`13项、`git diff --check`。
- [ ] Step 5: 提交`feat: expose focus sessions and personal speech in native controls`，task-done完整`bash scripts/test.sh`。

## Final review and local delivery

- [ ] 按executing-plans生成整个分支review-package，从d837afb到最终源代码提交，单次独立只读评审；执行者裁定并用RED→GREEN处理Critical/Important，不把评审当运行验证。
- [ ] 从干净提交导出并构建两个架构，运行`python3 -m unittest discover -s Tests/Distribution -v`；检查签名、素材哈希、DMG/ZIP库存及八附件`prepare-release.py --check-only`。
- [ ] 隔离真实Bundle验证三套旧皮肤、四类个人台词、关闭/隐藏/暂停/完成；真实1分钟计时独立运行。原生渲染六Tab、长编辑器与最小窗口；保留图片，逐图检查。机器睡眠、物理键鼠/焦点、Intel/外机仍需真实观察。
- [ ] ARM从DMG复制到中文/空格路径，弹出后在工程外启动、退出重开，剥离开发环境；不得当作外机验证。
- [ ] 按准确可执行路径正常退出旧App，备份旧App及退出后配置，更新/Applications/YeShunguangPet.app；核对迁移和旧个人状态，新计时默认ready。保持供用户体验；不触碰正式登录项。
- [ ] 保存实际验证与来源、提交文档、本地分支保留，工作区干净。不推送、打标签、建草稿或发布。
