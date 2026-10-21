# YeShunguangPet macOS

为 Mac mini M4 日常试用制作的原生 Swift + AppKit 单角色桌宠，沿用 [Windows 版](https://github.com/Resker666/YeShunguangPet) 的皮肤格式与真实素材。当前为免费分发体验版 0.1.8。

延后验证事项与后续候选路线见 [项目待办](TODO.md)。日用设置见 [设置验证记录](docs/settings-validation.md)；皮肤导入与切换见 [皮肤导入记录](docs/skin-import-validation.md)，已有副本管理见 [皮肤库验证记录](docs/skin-library-validation.md)，注视与资源采样见 [注视验证记录](docs/gaze-validation.md)，自动小动作见 [验证记录](docs/automatic-actions-validation.md)，小范围走动见 [走动验证](docs/roaming-validation.md)。

## 安装体验版

使用者不需要安装 Xcode、Swift 或其他依赖。日用包请选择 M 系列 Mac（arm64）；另提供x86_64实验包用于Intel／黑苹果验证。两种包分开，文件名标明架构。部署目标仍为15.0，仅 M4 / macOS 27.0 实测，真实Intel／黑苹果及其他系统尚待验证。

1. M 系列打开 `YeShunguangPet-0.1.8-macOS-arm64.dmg`；Intel测试机选择文件名以`x86_64.dmg`结尾的实验包。将 App 拖到旁边的 Applications。
2. 弹出 DMG，从“应用程序”打开 App；菜单栏爪印提供操作和退出入口。
3. 免费体验版使用 ad-hoc 签名，未公证。网上下载后若系统拦截，请先核实来源，在尝试打开后按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 前往“隐私与安全性 → 仍要打开”。DMG 不会消除系统提示。

备用ZIP含对应架构的App和安装说明；安装、更新、卸载及配置保留说明见 [安装说明](docs/installation.txt)。0.1.1分发记录见 [分发记录](docs/distribution-validation.md)；双架构构建证据和限制见 [Intel测试包记录](docs/intel-validation.md)。

## 打开与退出

本机构建产物为 `dist/YeShunguangPet.app`。双击 App，或在仓库根目录运行：

```bash
open dist/YeShunguangPet.app
```

菜单栏爪印提供 **显示/隐藏角色、召回角色、设置、退出**。拖动角色移动位置；单击挥手，双击跳跃。单击等待系统双击间隔后触发，拖动不会补发点击。缺失动作按原版规则回退。

支持注视素材的皮肤在待机时会短暂看向附近鼠标，最多约2秒，然后恢复待机；鼠标离开有效范围再靠近可再次触发。“设置…”中的“注视鼠标”默认开启，可关闭并记住选择。关闭设置窗口后生效；菜单、设置、点击判定、拖动和手动动作期间暂停注视，隐藏、睡眠及退出时停止检测。不支持注视的皮肤继续正常待机，偏好保留。

“设置…”中的“空闲时自动做动作”默认关闭。开启后关闭设置窗口，角色会按约60秒的间隔做小动作；可调15–120秒，每次有±25%浮动。沿用皮肤behavior的条件、权重和冷却；旧皮肤从可用挥手/跳跃选择，显式空规则不触发。菜单、设置、点击、拖动、手动动作、隐藏及睡眠暂停全局等待，恢复后继续；关闭开关中止自动动作。

“设置…”中的“空闲时走动一小段”默认关闭，间隔20–180秒，默认约75秒且有±25%浮动。角色在当前屏幕可用区域内左右移动约60–120逻辑点，完成后回待机并保存位置。鼠标靠近时原地停下，离开后继续；点击、拖动、菜单、设置、手动动作、隐藏及睡眠会结束本次走动，再等待下一次。皮肤需同时提供左右循环行走动画；空间不足时保持待机。

App 不显示 Dock 图标；请从菜单栏退出。首次启动会在主屏右下角显示角色，后续恢复位置、大小和置顶偏好。关闭设置窗口不会退出桌宠。基础桌宠不需要录屏、辅助功能或麦克风权限。

支持目标为 macOS 15+ / arm64，实际构建和验证环境为 Mac mini M4、macOS 27.0、Xcode 27.0。其他系统版本、Intel Mac 未测。角色窗口采用非激活 NSPanel，默认浮动置顶；设置窗口可以正常获得键盘焦点。Spaces、全屏、Stage Manager 和真实睡眠恢复的当前证据见 [验证记录](docs/validation.md)，不能保证覆盖所有系统窗口。

## 皮肤与配置

默认随附未经改写的叶瞬光 JSON/PNG。角色默认以格尺寸对应逻辑点显示，叶瞬光为192×208点。“设置…”提供50%–200%大小调整及置顶开关，立即生效并自动保存；关闭置顶后角色可能被其他窗口遮挡，可从菜单栏召回。

在设置的“皮肤”区域点“选择皮肤…”，选择解压后的皮肤文件夹或`pet.json`，查看名称与待机首帧预览，再点“导入并使用”。清单与对应PNG会按原字节复制到`~/Library/Application Support/YeShunguangPet-macOS/Skins/`，不依赖下载目录中的原文件；再次启动恢复所选皮肤。校验、复制或保存失败时继续使用当前角色，显示具体原因。“恢复默认皮肤”切回随附叶瞬光。取消预览不会导入；关闭设置窗口会取消尚未确认的操作。

设置中的“已导入皮肤”自动识别之前保存的副本，显示名称、待机缩略图与使用状态；点“使用”即可切换，不必重新选择原文件，也不增加副本。可以确认删除未使用的副本，原始文件保持不变；当前使用、配置仍记住的皮肤或原配置受保护时不可删除。损坏的副本单独显示错误，可以删除，不影响其他皮肤。“刷新皮肤列表”重新读取受管理目录。

重复导入仍会保存独立副本；只想换回旧角色时请使用列表。正常退出会等待当前导入完成，再清理本次未使用的副本；强制结束或断电没有此保证，也不会自动清空历史副本。暂不支持直接选择ZIP，请先解压。也可以从终端指定一个仅用于本次启动的本地皮肤：

```bash
dist/YeShunguangPet.app/Contents/MacOS/YeShunguangPet --skin /绝对路径/pet.json
```

显式指定的皮肤加载失败时，菜单栏显示错误并保留退出入口，不静默回退。皮肤文件不会被编辑。`lookDirections`用于16向注视；`behavior`用于可选自动动作，`speech`会校验但暂不执行台词，详见 [兼容矩阵](docs/skin-compatibility.md)。输入按角色矩形处理，逐像素透明区域穿透未验证。

位置、显示偏好、注视/自动动作/走动开关、对应间隔和所选导入皮肤保存在 `~/Library/Application Support/YeShunguangPet-macOS/settings.json`。新版读取schemaVersion 1–5，保存为6；旧版App无法读取新版配置，会保留原文件而不覆盖。导入素材缺失或损坏时恢复默认角色，在菜单栏和设置中提示原因。隐藏状态不跨进程保存，重新启动默认显示。损坏或未知版本配置不会被自动覆盖；菜单栏提供“备份原配置并重置”。保存失败会在设置窗口和菜单栏提示，可重试，也可明确选择继续退出。

开发检查可设置 `YSGPET_SETTINGS_PATH` 为隔离配置的绝对路径，导入素材也隔离在该文件同级的`Skins/`；`YSGPET_METRICS_PATH` 为退出时的本地运行指标输出路径。普通启动不启用指标输出，不联网、不上传日志。

## 构建和测试

需要完整 Xcode，使用系统框架，无第三方运行库或工程生成依赖。

```bash
bash scripts/test.sh
bash scripts/build-app.sh
python3 scripts/smoke-app.py
bash scripts/package-app.sh
# 额外构建并打包Intel实验版（不会替换上述ARM App）：
bash scripts/build-app.sh x86_64
bash scripts/package-app.sh x86_64
# 两个架构的App均构建后，在M系列开发机执行完整分发检查：
python3 -m unittest discover -s Tests/Distribution -v
# 指定已搬离工程目录的 App，并验证二次启动恢复位置：
python3 scripts/smoke-app.py --app /绝对路径/YeShunguangPet.app --check-restore
```

也可在 Xcode 打开 `YeShunguangPet.xcodeproj`，选择共享 scheme `YeShunguangPet`。测试使用临时目录，不修改个人配置。`.build/` 和 `dist/` 不进入 Git。

构建需要 Xcode；使用 App 不需要。默认ARM App在`dist/YeShunguangPet.app`，Intel App在`dist/x86_64/YeShunguangPet.app`。两者主程序和嵌入框架架构必须一致；打包时会核对所选架构，拒绝错误标签或混合框架。

打包输出均在dist根目录，带版本号和架构的DMG、ZIP及各自SHA-256文件。例如在 dist/ 内运行 `shasum -a 256 -c YeShunguangPet-0.1.8-macOS-arm64.dmg.sha256`。SHA-256用于文件完整性校验，不等同于开发者认证。包仍未做Developer ID签名、公证或公开发布，`Contents/Resources/build-info.json`记录构建提交和架构。

## 云端构建与下载

GitHub Actions 的 [macOS App 流水线](.github/workflows/macos-build.yml)在推送至`main`或`codex/**`、提交面向`main`的PR时自动运行，也支持手动触发。使用`macos-26`的Apple Silicon机器、Xcode 26.6，复用上述测试/构建/打包脚本；本机开发使用Xcode 27，两种环境的验证结果分别记录。

原生测试、双架构Release构建及完整分发回归通过后，上传ARM与Intel两份安装产物，名称包含版本、架构、运行编号和重试次数。每份含DMG、ZIP及各自SHA-256；App、安装说明和许可已封装在安装包内，避免直接上传App目录丢失执行权限或链接。另保留环境、构建/测试日志和XCTest结果，失败时也尝试上传诊断产物。产物保留14天，流水线不创建GitHub Release。

推送工作流后，打开[仓库Actions页面](https://github.com/Resker666/YeShunguangPet-macOS/actions)，选择`macOS App`的一次成功运行，在摘要的下载链接或底部`Artifacts`下载对应架构；需登录GitHub。下载的外层ZIP先解压，再按上文安装其中的DMG或备用ZIP。手动运行时选择`macOS App → Run workflow`；该入口需工作流先进入默认分支。具体流程、排错及验证边界见[CI说明](docs/ci.md)。

App 图标由原仓库 ICO 转换，原图256×256；大尺寸仅作缩放，不新增绘制细节。需要重新生成时运行 `bash tools/make-icon.sh`，使用系统 sips/iconutil，无外部图像工具依赖。

## 项目与素材

独立 Mac 仓库与 Windows 工程分别维护；本次没有改动 Windows 仓库。Minimal Sleep 复用了已安装的 Swift/Xcode 工具以及时钟、存储的设计经验，手机音频实现未进入此 App。

程序源码采用 [MIT](LICENSE)。角色图像、名称等第三方内容不属于 MIT 素材授权，见 [素材声明](ASSET_NOTICE.md) 和 [资源来源](docs/resource-provenance.md)。
