# Mac 开发约定
适用于本仓库。先读 docs/superpowers/specs/2026-10-20-macos-first-playable-design.md 和对应 plans 文件，检查 git status。
- Swift 6、AppKit、macOS 15+、arm64；使用现有 Xcode，不引入外部依赖。
- 测试：bash scripts/test.sh；构建：bash scripts/build-app.sh；打包：bash scripts/package-app.sh。
- 真实皮肤 JSON/PNG 字节保持不变；源码 MIT 与第三方素材声明分开。
- Windows 仓库和 Minimal Sleep 仅作只读参考，保留其原有改动。
- 配置在 Application Support；测试使用临时目录，不覆盖个人状态。
- 构建和真实交互分别报告；未验证的系统场景标记未测。
- 只做本地提交；未经用户明确指令不推送、打标签或发布。
