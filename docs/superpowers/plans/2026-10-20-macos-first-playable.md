# YeShunguangPet macOS First Playable Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付在用户 Mac mini M4 上可打开、加载真实旧皮肤、动画互动、保存位置且可从菜单栏退出的 arm64 App。

**Architecture:** 使用原生 Xcode 工程，将皮肤、播放、输入和位置逻辑放入 PetCore，将 NSPanel、绘制、单次定时器和菜单栏放入 AppKit 应用。PetSession 在主线程组合组件；纯逻辑使用独立 XCTest，原生适配用自建窗口和临时配置检查。

**Tech Stack:** Swift 6、AppKit、Foundation、CoreGraphics、ImageIO、XCTest、xcodebuild、codesign、ditto；无外部包与工程生成器。

**Spec:** [已批准的首版设计](../specs/2026-10-20-macos-first-playable-design.md)。执行前读完该设计和本计划。

## Global Constraints

- 工作目录为 `/Users/resker/develop/github/YeShunguangPet-macOS`；Windows 参考副本 `/private/tmp/YeShunguangPet-reference` 只读，参考提交为 `242aab04c6b6fc94e107eefa9fa216a4ee2e77e7`。
- 部署目标设为 macOS 15.0，产物为 arm64；应用标识使用 `io.github.resker666.yeshunguangpet.macos`。实际验证环境为 M4 / 16 GB / macOS 27.0 / Xcode 27.0 / Swift 6.4。
- 使用原生 Xcode 工程、系统框架和 XCTest，不依赖 XcodeGen、游戏引擎或外部运行库。
- 随附 `Pets/YeShunguang/pet.json` 与 `spritesheet.png` 保留原字节，SHA-256 以设计第 2 节为准；原程序 MIT 许可及素材声明分别保留。
- 接受原有 schemaVersion 1，包括合法 `lookDirections`、`speech`、`behavior` 的读取校验；首版不执行注视、台词或自动行为。
- JSON 最大 128 KiB、最大嵌套 64 层；PNG 最大 64 MiB、每边最大 8192、总像素最大 16,777,216；配置最大 64 KiB。
- 窗口尺寸取已加载皮肤的单格尺寸，同值转换为逻辑点；默认叶瞬光为 192×208 逻辑点。拖动阈值在任一轴绝对位移超过 4 逻辑点时满足。
- 窗口为无边框非激活 NSPanel，`.floating`、`.canJoinAllSpaces`、`.fullScreenAuxiliary` 是待实测的初始参数；首版命中范围是完整单元格矩形。
- 配置路径为 `~/Library/Application Support/YeShunguangPet-macOS/settings.json`；配置独立于皮肤。冷启动默认显示，召回到主屏可用区域右下角、距边缘 24 点。
- 只有皮肤有效、角色可见且系统已唤醒时，才恢复保留的播放位置并安排一个后续期限。
- 首版不增加登录、自启动、网络请求、自动更新、皮肤管理、缩放、多角色、专注、AI、截图或 OCR；不申请录屏或辅助功能权限。
- Minimal Sleep 仅供参考已装工具、时钟与存储模式，不复制其个人签名设置或整段 Apache-2.0 源码；其原有未提交改动保持原样。
- 只有用户明确指令才推送、打标签或发布；提交仅保存在本地。开始执行前按 using-git-worktrees 技能确认隔离状态，优先复用当前独立且干净的 Mac 仓库。

## Review Focus

1. 转义后的 JSON 键或大小写不同的重复键不能躲过检查；布尔值不能被当作数字接受。归任务 1。
2. 符号链接、读取过程中增长的文件、看似有合法 IHDR 但无法解码的 PNG，不能进入角色运行。归任务 2。
3. 第二次按下变成拖动、菜单或隐藏发生后，旧单击回调不得继续播放动作。归任务 4。
4. 角色先隐藏再经历睡眠与唤醒，动画仍应停止；重复恢复事件只能留下一个调度。归任务 4。
5. 损坏或未知版本配置在拖动、召回和退出时不能被自动覆盖；保存失败仍能明确退出。归任务 5。

## File Structure

| 路径 | 责任 |
| --- | --- |
| `YeShunguangPet.xcodeproj/project.pbxproj` | PetCore framework、App 和两个 XCTest target；不带 Team ID |
| `YeShunguangPet.xcodeproj/xcshareddata/xcschemes/YeShunguangPet.xcscheme` | 共享构建与测试入口 |
| `Sources/PetCore/Skin/{StrictJSON,PetManifest,ManifestDecoder}.swift` | 保留键的 JSON 检查、强类型模型和格式语义 |
| `Sources/PetCore/Skin/{SkinLoader,SpriteAtlas}.swift` | 有界本地读取、PNG 解码和裁帧缓存 |
| `Sources/PetCore/Runtime/SpritePlayback.swift` | 不依赖定时器的累计帧期限 |
| `Sources/PetCore/Runtime/PetInteraction.swift` | 单击、双击、拖动与取消 |
| `Sources/PetCore/Runtime/RuntimeGate.swift` | 可见性与睡眠暂停条件 |
| `Sources/PetCore/Placement/WindowPlacement.swift` | 多屏位置恢复和召回的纯几何算法 |
| `Sources/PetCore/Persistence/SettingsStore.swift` | 有界读写、保护状态和显式备份重置 |
| `Sources/YeShunguangPet/{main,AppDelegate,LaunchOptions}.swift` | 入口、NSApplication accessory 模式、开发参数解析 |
| `Sources/YeShunguangPet/{PetPanel,PetView,PetSession}.swift` | 窗口、绘制、原生事件与会话组合 |
| `Sources/YeShunguangPet/{FrameScheduler,StatusBarController,ScreenProvider}.swift` | 单次唤醒、菜单栏、屏幕与系统通知适配 |
| `Sources/YeShunguangPet/Info.plist` | 标识、版本 0.1.0、最低系统与 LSUIElement |
| `Resources/Pets/YeShunguang/{pet.json,spritesheet.png}` | 原始旧皮肤 |
| `Tests/PetCoreTests/` | schema、资源、时钟、输入、几何与存储测试 |
| `Tests/PetMacTests/` | 自建窗口、菜单、调度与会话整合检查 |
| `Tests/Support/SkinFixtures.swift` | 小型 JSON 和带方向/透明度的 PNG 夹具，只使用合成数据 |
| `Tests/Fixtures/LegacyManifests/{ye-shunguang,robin,hutao}.json` | 三份原版清单的只读测试副本；测试不依赖临时参考库存在 |
| `scripts/{test,build-app,package-app}.sh` | 可复用命令，错误时非零退出 |
| `tools/sample_process.py` | 有界进程 CPU/RSS 采样，不读取其他进程内容 |
| `README.md`、`AGENTS.md`、`.gitignore` | 运行、真实构建入口、协作与忽略规则 |
| `LICENSE`、`ASSET_NOTICE.md`、`docs/resource-provenance.md` | 程序许可、素材边界、参考提交与哈希 |
| `docs/{skin-compatibility,validation}.md` | 功能兼容矩阵与真实验证证据 |

PetCore 是可测试的系统框架代码；App 显式链接并嵌入 PetCore.framework。PetCoreTests 为无 App host 的 XCTest，避免测试自动启动个人角色。任务 4 增加同样无 host 的 PetMacTests：直接编译同一份 Mac 适配源文件，排除 main.swift 与 AppDelegate.swift，通过注入临时目录检查原生对象。生产逻辑只维护一份源码。

## Commands

以下是计划中的命令，尚未执行；相关工程和脚本在任务内创建。所有 shell 脚本使用 `set -euo pipefail`，日志保存在忽略的 `.build/`。

```bash
# 工程可测试后，统一运行入口：透传 -only-testing 等 xcodebuild 参数
bash scripts/test.sh -only-testing:PetCoreTests/ManifestDecoderTests
# test.sh 执行 xcodebuild -project YeShunguangPet.xcodeproj -scheme YeShunguangPet
#   -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/tests
#   CODE_SIGNING_ALLOWED=NO test "$@"

bash scripts/build-app.sh
# Release，arm64，CODE_SIGNING_ALLOWED=NO；复制产品到 dist/ 后签本地 ad-hoc 签名
bash scripts/package-app.sh
# ditto 保留包结构；在 dist/ 内生成并检查 ZIP 的 SHA-256
```

每个任务提交前运行 `git diff --check` 和该任务相关测试。除下方明确的首次 RED 外，编译失败、运行权限问题与用例断言失败分别记录，不能将环境失败当作需求测试已正确失败。

### Task 1: 严格 manifest 合同与独立测试入口

**Files:** 创建 Xcode 工程及共享 scheme 的 PetCore / PetCoreTests 部分；创建 `Sources/PetCore/Skin/{StrictJSON,PetManifest,ManifestDecoder}.swift`、`Tests/PetCoreTests/{StrictJSONTests,ManifestDecoderTests}.swift`、`Tests/Support/SkinFixtures.swift`、`Tests/Fixtures/LegacyManifests/{ye-shunguang,robin,hutao}.json`、`scripts/test.sh`、`.gitignore`、`AGENTS.md`、`LICENSE`。

**Interfaces:**
- 产生 `PetAction: String, CaseIterable` 的九个原版动作，`FrameLocation(row: Int, column: Int)`、`AnimationDefinition(row: Int, startColumn: Int, durationsMs: [Int], loop: Bool)`。
- 产生不可变 `PetManifest`：schemaVersion、id、name、description、spriteSheet、cellWidth、cellHeight、columns、rows、animations、lookDirections、speech、behavior；可选字段的内部结构与原参考类对应。
- 产生 `ManifestDecoder.decode(_ data: Data) throws -> PetManifest`、`StrictJSON.validate(_ data: Data) throws`。错误以 `SkinError: Error, LocalizedError` 表达，带字段路径；所有皮肤阶段共用此错误边界。
- 产生 `SkinFixtures.minimalManifest: Data`，其内容就是规范中 32×32、2 列、1 行、idle `[300,200]` 的有效清单；`SkinFixtures.replacing(_:with:in:)` 为明确字节替换的测试辅助。

- [x] **Step 1: 建立最小原生测试工程并写失败用例。** 仅建立任务需要的 target、scheme 和 test.sh；加入下面的 RED 测试，产品类型先不实现。`.gitignore` 忽略 `.build/`、`dist/`、DerivedData、xcuserdata、结果包和签名文件。AGENTS 写入实际计划入口、原仓库只读及发布规则。复制原 MIT LICENSE 和三个原版清单测试副本，测试通过 Bundle 读取副本。

```swift
func testMinimalManifestDefaultsAndIdle() throws {
    let pet = try ManifestDecoder.decode(SkinFixtures.minimalManifest)
    XCTAssertEqual(pet.id, "my-pet")
    XCTAssertEqual(pet.spriteSheet, "spritesheet.png")
    XCTAssertEqual(pet.animations[.idle]?.durationsMs, [300, 200])
    XCTAssertEqual(pet.lookDirections.count, 0)
    XCTAssertNil(pet.speech)
}
func testEscapedDuplicateAndBooleanIntegerAreRejected() {
    let duplicate = Data(#"{"id":"a","\u0069d":"b"}"#.utf8)
    XCTAssertThrowsError(try StrictJSON.validate(duplicate))
    let booleanVersion = SkinFixtures.replacing("\"schemaVersion\": 1", with: "\"schemaVersion\": true", in: SkinFixtures.minimalManifest)
    XCTAssertThrowsError(try ManifestDecoder.decode(booleanVersion))
}
```

- [x] **Step 2: 验证 RED。** 运行 `bash scripts/test.sh -only-testing:PetCoreTests/ManifestDecoderTests`；首次应因产品类型尚未定义而编译失败。工程本身必须能被 `xcodebuild -list -project YeShunguangPet.xcodeproj` 识别；否则先修工程配置，不能记作正确 RED。

- [x] **Step 3: 实现结构检查和模型解码。** StrictJSON 做有界 token 遍历，解码字符串键后按原版不区分大小写拒绝重复，不用正则检查 JSON。随后按原版允许键、确切类型、默认值和 UTF-16 长度规则构造模型；整数不接受小数、指数形式或布尔别名。源文件为原版 `PetPackage.cs`、`PetBehaviorRules.cs`、`PetSpeech.cs`。

- [x] **Step 4: 增加有值断言的边界用例并验证 GREEN。** 表驱动覆盖 schema 0/1/2，ID 和保留名，BOM/无效 UTF-8，128 KiB/超一字节，64/65 层，尾逗号/未知键/大小写别名/嵌套重复，合法可选字段及 null 区别，16/512 格、1/64 行列，20/10000 ms，非循环 idle、循环 waving、越行帧。`testOptionalFieldsPreserveDefaultsAndNullRules` 断言 speech/behavior 为 null 合法而 lookDirections 为 null 失败；`testBehaviorLimitsAndReferences` 断言 9/10 条、权重 1/100 与 0/101、冷却 5/3600 与 4/3601、动作总长 30000/30001 ms 的边界结果；`testSpeechUsesUTF16Length` 断言 40 个 emoji 的 80 个 UTF-16 单元可接受，41 个不可接受。读取三个旧清单副本均应成功，不更改参考源文件。运行 `bash scripts/test.sh`，要求所有当前 XCTest 通过。

- [x] **Step 5: 本地提交。** `git add Sources/PetCore/Skin Tests scripts/test.sh YeShunguangPet.xcodeproj .gitignore AGENTS.md LICENSE`，提交 `feat: validate legacy pet manifests with strict JSON semantics`。

### Task 2: 安全加载真实旧皮肤并验证裁帧

**Files:** 创建 `Sources/PetCore/Skin/{SkinLoader,SpriteAtlas}.swift`、`Tests/PetCoreTests/{SkinLoaderTests,SpriteAtlasTests}.swift`、真实 `Resources/Pets/YeShunguang/`、`ASSET_NOTICE.md`、`docs/resource-provenance.md`；扩展 `Tests/Support/SkinFixtures.swift` 和测试资源配置。

**Interfaces:**
- 消费 `ManifestDecoder.decode(_:)`、`PetManifest`、`FrameLocation`、`SkinError`。
- 产生 `LoadedSkin { let manifest: PetManifest; let spriteSheet: CGImage; let directory: URL }`。
- 产生 `SkinLoader.load(manifestURL: URL) throws -> LoadedSkin`，以及内部 `readFile(at: URL, maximumBytes: Int) throws -> Data`，供配置阶段复用有界普通文件读取。
- 产生 `SpriteAtlas.init(skin: LoadedSkin)`、`frame(at location: FrameLocation) throws -> CGImage`；像素坐标以原图左上为原点。
- 夹具产生 `SkinFixtures.writePackage(in: URL) throws -> URL`（返回 pet.json URL）与 `directionalPNG() throws -> Data`（64×32，上半红、下半蓝，左右帧不同且有透明角）。

- [x] **Step 1: 写真实资源和方向测试。** 先复制原版 JSON、PNG、MIT LICENSE 和素材声明，核对设计中的两份 SHA-256；测试使用复制品，不从参考库读写运行状态。

```swift
func testLegacySkinDimensionsAndFirstCrop() throws {
    let skin = try SkinLoader.load(manifestURL: legacyManifestURL)
    XCTAssertEqual(skin.manifest.id, "ye-shunguang")
    XCTAssertEqual(skin.spriteSheet.width, 1536)
    let frame = try SpriteAtlas(skin: skin).frame(at: .init(row: 0, column: 0))
    XCTAssertEqual(frame.width, 192)
    XCTAssertEqual(frame.height, 208)
}
```

`legacyManifestURL` 在用例 setUp 中从 XCTest Bundle 的 `Pets/YeShunguang/pet.json` 解析。另用方向夹具逐点断言顶部红、底部蓝、透明角 alpha=0、第二列不同，不能只检查图像非空。

- [x] **Step 2: 验证 RED。** 运行 `bash scripts/test.sh -only-testing:PetCoreTests/SkinLoaderTests -only-testing:PetCoreTests/SpriteAtlasTests`；预期缺少加载和裁帧实现，或方向断言失败。

- [x] **Step 3: 实现有限读取与 PNG 加载。** 限制读取字节数而非仅预先 stat；对目录和文件检查链接，对已经打开的普通文件再检查类型和大小。资源名只允许当前目录，拒绝 URL、分隔符、Windows 非法字符和链接；拒绝大小不符或损坏 PNG。ImageIO 实际解码前检查 PNG signature、IHDR 和模型尺寸；缓存裁剪 CGImage，保留 alpha 和原方向。

- [x] **Step 4: 验证拒绝用例与 GREEN。** 添加 root/PNG/manifest 为链接、`../`/反斜杠/URL、空文件、PNG 64 MiB 超一字节、合法头但损坏数据、尺寸不符、读取时文件增大仍受上限约束的测试；用可控流读取辅助测增长，不依赖不稳定并发时序。运行 `bash scripts/test.sh`，并再次核对复制资源哈希；写 provenance 的提交、路径和素材边界。

- [x] **Step 5: 本地提交。** 暂存本任务文件，提交 `feat: load and crop unchanged legacy pet skin resources`。

### Task 3: 确定性动画时钟

**Files:** 创建 `Sources/PetCore/Runtime/SpritePlayback.swift`、`Tests/PetCoreTests/SpritePlaybackTests.swift`；更新工程 target membership。

**Interfaces:**
- 消费已校验的 `AnimationDefinition`。
- 产生 `PlaybackSample { let index: Int; let completed: Bool; let untilNextFrame: Duration? }`。
- 产生 `SpritePlayback.init(now: @escaping () -> Duration)`、`mutating start(_ animation: AnimationDefinition)`、`mutating pause()`、`mutating resume()`、`sample() -> PlaybackSample`。暂停或结束时 next=nil，不要求定时器继续轮询。
- 时钟返回从固定起点流逝的 Duration，保留整数时间精度；生产使用 ContinuousClock，测试用局部变量推进。

- [x] **Step 1: 写不等长帧和暂停测试。**

```swift
func testUnequalFrameBoundaryAndLoop() {
    var now = Duration.zero
    var playback = SpritePlayback(now: { now })
    playback.start(.init(row: 0, startColumn: 0, durationsMs: [300, 200], loop: true))
    now = .milliseconds(300)
    XCTAssertEqual(playback.sample().index, 1)
    now = .milliseconds(500)
    XCTAssertEqual(playback.sample().index, 0)
    now = .seconds(3600) + .milliseconds(450)
    XCTAssertEqual(playback.sample().index, 1)
}
```

另测 pause 后推进一小时位置不变、next=nil，resume 后从剩余期限续播；不以真实 sleep 等待来测试时间。

- [x] **Step 2: 验证 RED。** `bash scripts/test.sh -only-testing:PetCoreTests/SpritePlaybackTests`，预期产品类型缺失或边界断言失败。

- [x] **Step 3: 实现累计期限。** 将各帧毫秒累计为 Duration；循环取模、单次结束停在最后一帧，精确命中某帧结束时进入下一帧。pause/resume 可重复调用，不重置已保存进度；长延迟直接定位，不逐帧推进。

- [x] **Step 4: 验证 GREEN。** 补齐空启动前快照、一次动作完成、同动作重新 start、重复 pause/resume、长延迟和负时间输入按零处理。运行 `bash scripts/test.sh`。

- [x] **Step 5: 本地提交。** 提交 `feat: schedule sprite playback from monotonic frame deadlines`。

### Task 4: 首个可运行透明桌宠、输入和生命周期

**Files:** 创建 `Sources/PetCore/Runtime/{PetInteraction,RuntimeGate}.swift`、`Sources/YeShunguangPet/` 表列文件（ScreenProvider 延至任务 5）、`Tests/PetCoreTests/{PetInteractionTests,RuntimeGateTests}.swift`、`Tests/PetMacTests/{PetPanelTests,FrameSchedulerTests,PetSessionTests,LaunchOptionsTests}.swift`、`scripts/build-app.sh`；更新 `Sources/PetCore/Skin/PetManifest.swift`，工程增加 App/PetMacTests、资源和共享 scheme 的运行项。

**Interfaces:**
- 消费 LoadedSkin、SpriteAtlas、SpritePlayback。生产框架内增加 `PetManifest.resolve(_ requested: PetAction) -> PetAction`：jumping→waving→idle，其余缺失动作→idle。
- 产生引用类型 `final class PetInteraction`：`init(doubleClickInterval: Duration, now: @escaping () -> Duration)`、`pointerDown(at: CGPoint, clickCount: Int)`、`pointerMoved(to: CGPoint) -> [InteractionEffect]`、`pointerUp(at: CGPoint) -> [InteractionEffect]`、`expireClick() -> [InteractionEffect]`、`cancel()`、只读 `nextClickDeadline: Duration?`。
- `InteractionEffect` 为 `.beginDrag`、`.drag(delta: CGSize)`、`.finishDrag`、`.play(PetAction)`；delta 相对于最初按下点，Session 在 beginDrag 保存窗口原点。4 点以内移动不产生拖动；纯垂直拖动使用 idle。
- 产生值类型 `RuntimeGate`，四个 Bool 属性 loaded、visible、sleeping、exiting 初始均为 false；计算属性 `shouldRunFrames: Bool` 结果为 loaded && visible && !sleeping && !exiting。
- 产生 `FrameScheduler.init(now: @escaping () -> Duration, onFire: @escaping () -> Void)`、`schedule(after: Duration?)`、`cancel()`、只读 `pendingCount: Int`；每次 schedule 替换旧期限，cancel 后旧回调无效，0 表示无任务。
- 产生 `PetSession.init(skin: LoadedSkin, now: @escaping () -> Duration)`、`start()`、`setVisible(_:)`、`play(_:)`、`prepareToExit()`。此阶段窗口暂放主屏右下角，位置持久化由任务 5 接入。
- 产生 `LaunchOptions.parse(_ arguments: [String]) throws -> LaunchOptions`，只接受可选 `--skin /absolute/pet.json`，重复/缺值/相对路径/未知参数显示明确错误，不静默忽略。

- [x] **Step 1: 写输入和门控 RED 测试。**

```swift
func testSecondPressBecomesDragAndNeverClicks() {
    var now = Duration.zero
    let input = PetInteraction(doubleClickInterval: .milliseconds(500), now: { now })
    input.pointerDown(at: .zero, clickCount: 1)
    XCTAssertTrue(input.pointerUp(at: .zero).isEmpty)
    now = .milliseconds(100)
    input.pointerDown(at: .zero, clickCount: 2)
    let effects = input.pointerMoved(to: CGPoint(x: 5, y: 0))
    XCTAssertTrue(effects.contains(.beginDrag))
    _ = input.pointerUp(at: CGPoint(x: 5, y: 0))
    now = .seconds(1)
    XCTAssertTrue(input.expireClick().isEmpty)
}
```

InteractionEffect 和 PlaybackSample 的测试所需值比较实现 Equatable。另测试恰好 4 点不拖动、超过 4 点才拖动、正常单/双击、cancel 后 expireClick 无效、缺失动作回退，以及 hidden→sleep→wake 的 shouldRunFrames 始终为 false。

- [x] **Step 2: 验证 RED。** 运行 `bash scripts/test.sh -only-testing:PetCoreTests/PetInteractionTests -only-testing:PetCoreTests/RuntimeGateTests`；预期新类型缺失。

- [x] **Step 3: 实现纯输入状态和单一原生调度。** 完成上述接口。FrameScheduler 使用 NSRunLoop common modes 的单次 Timer，以单调时间复查剩余期限；安排、取消时递增代次，忽略旧回调。Session 的一次调度取帧更新与待判定单击的最早期限，不创建另一条固定频率循环。

- [x] **Step 4: 组合 AppKit 应用。** PetPanel 不成为 key/main；PetView 原生绘制并转发全局逻辑点鼠标坐标，拖动使用偏移。AppDelegate 进入 accessory 模式；StatusBarController 实现显示/隐藏、召回（本阶段回初始位置）、退出和加载错误。按设计配置窗口，菜单打开、隐藏、召回、睡眠、中断取消输入；系统睡眠及屏幕唤醒事件只更新 gate 后重新计算调度。窗口错误使用本地可读状态；不得无声退回有效默认皮肤。Info.plist 不含个人 Team ID、录屏/麦克风/辅助功能权限键。实现 build-app.sh：固定项目、scheme、Release 和 arm64，复制构建产品到 dist/，依次对 PetCore.framework 和 App 作 ad-hoc 签名，命令失败立即非零退出。

- [ ] **Step 5: 验证 GREEN 与原生可运行链路。**（自动部分完成；用户已确认拖动、单/双击、隐藏/显示和召回正常；菜单点击退出、焦点与系统场景未实测。） PetMacTests 在主线程检查 panel 不能 key/main、透明和实际 cell 尺寸、夹具绘制上下方向、menu 文案及加载失败无 panel、重复 schedule/cancel 只有一个有效回调、隐藏后唤醒 pendingCount=0、显示后恢复不积压。`LaunchOptionsTests.testRejectsMissingRepeatedRelativeAndUnknownArguments` 分别断言参数错误，`testAcceptsAbsoluteSkinPath` 断言准确 URL。使用临时自建 view、运行循环及有超时的 XCTest expectation，不截取用户桌面，不以固定 sleep 猜测回调已执行。运行 `bash scripts/test.sh`、`bash scripts/build-app.sh` 后打开本地 App；用真实鼠标确认旧皮肤动画、拖动、单/双击、菜单隐藏/显示/退出。在其他应用输入时确认显示与拖动不抢键盘，分别记录 Spaces/全屏的已观察结果；未能执行的场景列为未测。

- [x] **Step 6: 本地提交。** 提交 `feat: run an interactive transparent AppKit pet with menu bar controls`，记录当时实际构建与体验结果，不把属性断言写作系统场景通过。

### Task 5: 可靠位置保存、召回与坏配置保护

**Files:** 创建 `Sources/PetCore/Placement/WindowPlacement.swift`、`Sources/PetCore/Persistence/SettingsStore.swift`、`Sources/YeShunguangPet/ScreenProvider.swift`、`Tests/PetCoreTests/{WindowPlacementTests,SettingsStoreTests}.swift`；更新 PetSession、StatusBarController 与 PetSessionTests。

**Interfaces:**
- 产生 `ScreenArea { let id: String; let visibleFrame: CGRect; let isPrimary: Bool }`、`PlacementSnapshot: Codable, Equatable { let screenID: String; let origin: CGPoint; let visibleFrame: CGRect }`，JSON 使用明确数字字段，不序列化 NSWindow。
- 产生 `WindowPlacement.recall(size: CGSize, screens: [ScreenArea]) -> PlacementSnapshot?`、`restore(_ saved: PlacementSnapshot?, size: CGSize, screens: [ScreenArea]) -> PlacementSnapshot?`、`capture(origin: CGPoint, size: CGSize, screens: [ScreenArea]) -> PlacementSnapshot?`。capture 以窗口与屏幕交集最大者选屏；无交集选最近屏并限制原点。原屏变形时相对原点按可移动距离比例映射，退化距离按零处理，oversize 轴对齐 visibleFrame 最小边。
- 产生 `SettingsLoadResult` 的 `.missing`、`.loaded(PlacementSnapshot)`、`.protectedFile(message: String)`，以及 `SettingsStore.init(url: URL)`、`load() -> SettingsLoadResult`、`save(_:) throws`、`backupAndReset() throws`。内部只编码 `schemaVersion: 1` 和 placement；保护状态 save 明确失败，不写旧文件。
- Session 增加注入参数 `settings: SettingsStore`、`screens: () -> [ScreenArea]`，以及 `recall()`、`screensChanged()`、`retrySave()`、`resetProtectedSettings()`、`requestExit() -> Bool`（保存成功或无修改时可退出）；保存失败由菜单反馈，用户选继续退出才走 prepareToExit。
- ScreenProvider 优先用显示器 UUID，无法取得时使用带前缀的显示 ID；以 NSScreen.screens 的首屏为 primary，返回 visibleFrame 的逻辑点坐标。

- [x] **Step 1: 写位置和坏配置 RED 测试。**

```swift
func testRecallUsesVisibleFrameAndTwentyFourPointMargin() {
    let screen = ScreenArea(id: "main", visibleFrame: CGRect(x: 0, y: 40, width: 1000, height: 700), isPrimary: true)
    let p = WindowPlacement.recall(size: CGSize(width: 192, height: 208), screens: [screen])
    XCTAssertEqual(p?.origin, CGPoint(x: 784, y: 64))
}
func testCorruptSettingsRemainByteIdenticalUntilExplicitReset() throws {
    let bad = Data("{broken".utf8)
    try bad.write(to: settingsURL)
    let store = SettingsStore(url: settingsURL)
    guard case .protectedFile = store.load() else { return XCTFail("expected protection") }
    XCTAssertThrowsError(try store.save(validPlacement))
    XCTAssertEqual(try Data(contentsOf: settingsURL), bad)
}
```

settingsURL 和 validPlacement 在 setUp 中由本测试临时目录和已定义 PlacementSnapshot 建立。另测未知版本同样受保护，不因新实例自动覆盖。

- [x] **Step 2: 验证 RED。** `bash scripts/test.sh -only-testing:PetCoreTests/WindowPlacementTests -only-testing:PetCoreTests/SettingsStoreTests`，预期新接口缺失。

- [x] **Step 3: 实现几何与原子存储。** 按设计恢复、限制、映射和主屏回退；空屏幕返回 nil，屏幕小于角色仍保留最大可见区。SettingsStore 拒绝 >64 KiB、未知版本、无效数字与区域，异常原文件不改写；同目录临时文件完整写入后原子替换，失败清理临时文件并保留旧数据。显式 reset 先以唯一文件名备份原字节，备份失败则不解除保护；注入内部写入闭包确定性模拟磁盘失败，不依赖 chmod 或当前用户权限。

- [x] **Step 4: 接入实际位置与错误反馈。** 拖动结束、召回、屏幕变化修正、正常退出时保存；移动过程中不写盘。隐藏状态下屏幕变化只调整待恢复位置，不显示窗口。损坏配置显示可见恢复说明和“备份并重置”操作；保存失败显示“重试保存”，退出失败允许“继续退出/取消”，不循环弹窗。监听 NSApplication 屏幕参数变化与窗口切屏，避免位置修正引发重复保存递归。

- [x] **Step 5: 验证 GREEN。** 加入负坐标屏、Dock 改变、屏幕移除、屏幕重排、零可移动范围、oversize、无屏幕、文件重开、64 KiB/超一字节、写失败保旧字节/临时文件清理/重试、reset 备份失败保护保持等测试。PetSessionTests 验证 drag/recall/exit 不覆盖受保护文件，隐藏时 screensChanged 不显示，save 失败仍可明确退出。运行 `bash scripts/test.sh`；实际拖动后完全退出并重开检查恢复，再点召回检查可见位置。外屏拔插与真实分辨率切换仅在可执行时验证，否则列未测。

- [x] **Step 6: 本地提交。** 提交 `feat: persist pet placement and recover safely across display changes`。

### Task 6: arm64 本地交付与证据记录

**Files:** 完成 `scripts/{build-app,package-app}.sh`，创建 `tools/sample_process.py`、`README.md`、`docs/{skin-compatibility,validation}.md`，更新 `Sources/YeShunguangPet/{AppDelegate,PetSession,FrameScheduler}.swift` 的开发采样、`Tests/PetMacTests/PetSessionTests.swift`、AGENTS 与资源 provenance；产物只在忽略的 dist/，日志只在忽略的 .build/。

**Interfaces:**
- build-app.sh 成功生成 `dist/YeShunguangPet.app`，失败非零退出；先签嵌入的 PetCore.framework，再签 App，均为 `codesign --force --sign - --timestamp=none`，不使用个人证书。
- package-app.sh 只消费已验证 App，产生 `dist/YeShunguangPet-macOS-arm64.zip` 与 `.zip.sha256`，校验文件只写 ZIP 文件名。
- `python3 tools/sample_process.py --pid PID --duration 600 --interval 5 --output .build/performance.json`：验证 PID 属于本次启动的 App，只采集其进程 CPU 时间、RSS、单调采样时刻；进程退出时报告实际采样时长，不能记为完整 600 秒。
- `PetSession.exportMetrics(to url: URL) throws` 写调度唤醒数、实际绘帧数、实际会话时长；AppDelegate 仅在 `YSGPET_METRICS_PATH` 已设置时于退出前调用，失败写本机错误而不阻止退出。

- [x] **Step 1: 实现本地打包脚本。** package-app.sh 先核对主程序、PetCore.framework、资源哈希、架构和签名，再用 `ditto -c -k --sequesterRsrc --keepParent` 打包，并在 dist/ 内写出及检查 `.zip.sha256`。缺失或无效 App 必须非零退出，不上传文件。

- [x] **Step 2: 实现有界性能采样。** 在已有会话回调递增计数并实现 exportMetrics；用 XCTest 验证输出字段和写入失败不改变退出状态。Python 采样工具拒绝非本 App 的 PID、非正采样间隔和非正时长，使用单调时钟到期停止；目标进程提前结束时保留部分结果和实际时长，不自动附着到其他实例。普通 App 启动不启用指标输出。

- [x] **Step 3: 运行最终相关测试和 Release 构建。** 先完成 verification-before-completion skill，从菜单退出上一测试实例后再替换 dist/ 中的 App；不终止其他进程。运行 `bash scripts/test.sh` 和 `bash scripts/build-app.sh`，要求 XCTest `TEST SUCCEEDED`、Release `BUILD SUCCEEDED` 且退出码 0。保存原始日志；发生失败先定位并只重跑有根据的检查。

- [ ] **Step 4: 验证本机 App 包。**（包、架构、签名、资源和独立启动/正常退出均通过；菜单栏真实点击退出未实测。） `lipo -archs dist/YeShunguangPet.app/Contents/MacOS/YeShunguangPet` 必须仅 arm64；核对应用标识、LSUIElement、最低系统和资源哈希；运行 `codesign --verify --strict --verbose=2 dist/YeShunguangPet.app`。从 Finder 或 `open` 启动，确认角色与菜单出现；从菜单退出，记录对应 PID 已结束。签名验证不代替实际启动，也不等于公证。

- [ ] **Step 5: 执行有界日用检查。**（用户已确认基本互动；焦点和其他系统场景未测，按计划记录为限制。） 在实际显示器上检查透明与帧方向、拖动/单双击、菜单、重启恢复、其他应用输入、重复隐藏/显示、Spaces/全屏。锁屏/睡眠/Stage Manager 或外屏变更需要实际操作时先说明范围并等待用户配合，记录未执行项。禁止为了完成列表主动触发可能中断用户工作的锁屏、睡眠或系统设置改变。

- [x] **Step 6: 采集至少十分钟基线。** 实际可见单角色 idle 运行，记录显示器逻辑尺寸/backing scale、版本、采样时长、单核归一化 CPU（CPU 时间差/墙钟时间差×100）、RSS、调度唤醒次数和实际绘帧次数。开发环境变量 `YSGPET_METRICS_PATH` 指向 `.build/` 的本次汇总文件，不启动额外动画轮询，不记录其他应用或桌面内容。采样用独立进程在后台运行，工作中每分钟内给用户进展；不用长阻塞等待。运行不满 600 秒则报告实际结果并重新采完整样本；不可将短样本写作十分钟。

- [x] **Step 7: 完成文档与本地提交。** README 给出打开 App、如何菜单退出、配置路径、CLI 皮肤入口、矩形命中、系统场景限制和 ad-hoc 分发状态；skin-compatibility 区分读取与执行；validation 填命令、退出码、测试数量、实际系统行为、CPU/RSS、未测项和失败项。提交 `build: package arm64 app and record local validation`。随后以这个提交重新构建最终包并在本地证据记录其提交 ID，避免把先前构建冒充为该提交产物。

- [x] **Step 8: 打包、复核与交付。** 运行 `bash scripts/package-app.sh`，在 dist/ 内执行 `shasum -a 256 -c YeShunguangPet-macOS-arm64.zip.sha256` 必须 OK；解到临时目录确认包结构、资源哈希和签名仍有效。按选定执行方式完成全分支独立评审，修复阻断问题并重跑受影响检查。报告 App 绝对路径、启动/退出方式、已测与未测；原仓库仍无修改，Minimal Sleep 仍只有原有两处修改。不要推送、打标签或创建 Release。

## Plan Self-Review / 执行状态

用户已批准计划并选择本会话直接实施。任务 1–6 的实现与自动化检查已完成，十分钟基线已采集。用户已确认基本桌面交互正常；焦点和系统场景未测，具体限制见 validation.md。独立评审两项Important已用失败回归修复，全套40测试通过；最终arm64包已构建、签名、启动/正常退出并解包复核。未测系统场景保留未勾选，不阻断本地体验版交付。任务 1–2 对应设计皮肤合同和素材边界，任务 3–4 对应动画、窗口、输入与生命周期，任务 5 对应位置与错误恢复，任务 6 对应本机验证和交付；五项 Review Focus 分别有所属用例。

计划审阅通过后使用用户选择的执行方式。建议本会话直接实施：组件接口前后依赖明显，首版只有一个客户端；实施过程中保留逐任务验证与本地提交，最后进行独立评审。若用户选择分任务子代理，则按 subagent-driven-development 流程执行，并保留相同的系统实测门槛。上述选择均不授予推送或发布权限。
