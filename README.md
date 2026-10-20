# YeShunguangPet macOS

为 Mac mini M4 日常试用制作的原生 Swift + AppKit 单角色桌宠，沿用 [Windows 版](https://github.com/Resker666/YeShunguangPet) 的皮肤格式与真实素材。当前为免费分发体验版 0.1.1。

## 安装体验版

使用者不需要安装 Xcode、Swift 或其他依赖。当前仅提供 M 系列 Mac（arm64）包；部署目标15.0，仅 macOS 27.0 实测，其他系统和未安装 Xcode 的另一台 Mac 尚待验证。

1. 打开 `YeShunguangPet-0.1.1-macOS-arm64.dmg`，将 App 拖到旁边的 Applications。
2. 弹出 DMG，从“应用程序”打开 App；菜单栏爪印提供操作和退出入口。
3. 免费体验版使用 ad-hoc 签名，未公证。网上下载后若系统拦截，请先核实来源，在尝试打开后按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 前往“隐私与安全性 → 仍要打开”。DMG 不会消除系统提示。

备用ZIP含同一App和安装说明；安装、更新、卸载及配置保留说明见 [安装说明](docs/installation.txt)。本次分发验证范围见 [分发记录](docs/distribution-validation.md)。

## 打开与退出

本机构建产物为 `dist/YeShunguangPet.app`。双击 App，或在仓库根目录运行：

```bash
open dist/YeShunguangPet.app
```

菜单栏爪印提供 **显示/隐藏角色、召回角色、退出**。拖动角色移动位置；单击挥手，双击跳跃。单击等待系统双击间隔后触发，拖动不会补发点击。缺失动作按原版规则回退。

App 不显示 Dock 图标；请从菜单栏退出。首次启动会在主屏右下角显示角色，后续恢复位置。基础桌宠不需要录屏、辅助功能或麦克风权限。

支持目标为 macOS 15+ / arm64，实际构建和验证环境为 Mac mini M4、macOS 27.0、Xcode 27.0。其他系统版本、Intel Mac 未测。窗口采用浮动非激活 NSPanel；Spaces、全屏、Stage Manager 和真实睡眠恢复的当前证据见 [验证记录](docs/validation.md)，不能保证覆盖所有系统窗口。

## 皮肤与配置

默认随附未经改写的叶瞬光 JSON/PNG。单个角色以格尺寸对应逻辑点显示；默认 192×208 点。首版不提供缩放和皮肤管理。可以从终端指定另一个本地皮肤：

```bash
dist/YeShunguangPet.app/Contents/MacOS/YeShunguangPet --skin /绝对路径/pet.json
```

显式指定的皮肤加载失败时，菜单栏显示错误并保留退出入口，不静默回退。皮肤文件不会被编辑。`lookDirections`、`speech`、`behavior` 会校验，但首版不执行注视、台词和自动行为，详见 [兼容矩阵](docs/skin-compatibility.md)。输入按角色矩形处理，逐像素透明区域穿透未验证。

位置保存在 `~/Library/Application Support/YeShunguangPet-macOS/settings.json`。隐藏状态不跨进程保存，重新启动默认显示。损坏或未知版本配置不会被自动覆盖；菜单栏提供“备份原配置并重置”。保存失败可重试，也可明确选择继续退出。

开发检查可设置 `YSGPET_SETTINGS_PATH` 为隔离配置的绝对路径；`YSGPET_METRICS_PATH` 为退出时的本地运行指标输出路径。普通启动不启用指标输出，不联网、不上传日志。

## 构建和测试

需要完整 Xcode，使用系统框架，无第三方运行库或工程生成依赖。

```bash
bash scripts/test.sh
bash scripts/build-app.sh
python3 scripts/smoke-app.py
bash scripts/package-app.sh
# 构建 App 后，执行真实打包、挂载、搬移和回归检查：
python3 -m unittest discover -s Tests/Distribution -v
# 指定已搬离工程目录的 App，并验证二次启动恢复位置：
python3 scripts/smoke-app.py --app /绝对路径/YeShunguangPet.app --check-restore
```

也可在 Xcode 打开 `YeShunguangPet.xcodeproj`，选择共享 scheme `YeShunguangPet`。测试使用临时目录，不修改个人配置。`.build/` 和 `dist/` 不进入 Git。

构建需要 Xcode；使用 App 不需要。打包输出带版本号的 DMG、ZIP 及各自 SHA-256 文件。例如在 dist/ 内运行 `shasum -a 256 -c YeShunguangPet-0.1.1-macOS-arm64.dmg.sha256`。SHA-256 用于文件完整性校验，不等同于开发者认证。包仍未做 Developer ID 签名、公证或公开发布，`Contents/Resources/build-info.json` 记录构建提交。

App 图标由原仓库 ICO 转换，原图256×256；大尺寸仅作缩放，不新增绘制细节。需要重新生成时运行 `bash tools/make-icon.sh`，使用系统 sips/iconutil，无外部图像工具依赖。

## 项目与素材

独立 Mac 仓库与 Windows 工程分别维护；本次没有改动 Windows 仓库。Minimal Sleep 复用了已安装的 Swift/Xcode 工具以及时钟、存储的设计经验，手机音频实现未进入此 App。

程序源码采用 [MIT](LICENSE)。角色图像、名称等第三方内容不属于 MIT 素材授权，见 [素材声明](ASSET_NOTICE.md) 和 [资源来源](docs/resource-provenance.md)。
