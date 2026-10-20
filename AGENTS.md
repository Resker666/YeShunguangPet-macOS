# Mac 开发约定
适用于本仓库。先读 docs/superpowers/specs/2026-10-20-macos-first-playable-design.md 和对应 plans 文件，检查 git status。
- Swift 6、AppKit、macOS 15+；arm64优先日用，x86_64为用户同意增加的实验交叉构建。使用现有Xcode，不引入外部依赖。
- 测试：bash scripts/test.sh；构建：bash scripts/build-app.sh；打包：bash scripts/package-app.sh。独立启动回归：python3 scripts/smoke-app.py。
- 分发：0.1.2 / arm64和x86_64分别打包、ad-hoc、未公证；DMG和ZIP带版本号与架构，含安装说明与许可。build-app.sh和package-app.sh可传x86_64，默认ARM路径不变，Intel App单独在dist/x86_64。先构建两个架构，再在M系列开发机运行 python3 -m unittest discover -s Tests/Distribution -v。不要把交叉构建、签名、挂载检查写作Intel／黑苹果运行通过；也不要把本机搬移测试写作外机或Gatekeeper首开通过。
- 独立进程验证设置 YSGPET_SETTINGS_PATH 使用临时配置；不带该变量才使用个人 Application Support。
- 用户已确认真实拖动、单击/双击、菜单隐藏/显示和召回正常。GUI 工具首次超时，后续可读取实际角色画面；焦点、Spaces、锁屏和真实睡眠仍未验证，不能以属性或模拟事件当作通过。
- 真实皮肤 JSON/PNG 字节保持不变；源码 MIT 与第三方素材声明分开。
- Windows 仓库和 Minimal Sleep 仅作只读参考，保留其原有改动。
- 配置在 Application Support；测试使用临时目录，不覆盖个人状态。
- 构建和真实交互分别报告；未验证的系统场景标记未测。
- 只做本地提交；未经用户明确指令不推送、打标签或发布。
