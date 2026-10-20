# 免费分发体验版验证

日期：2026-10-20（Asia/Shanghai）。版本0.1.1，build 2；arm64，部署目标macOS 15.0。
实际机器仍为Mac mini M4、macOS 27.0（26A428）、Xcode 27.0。本记录不等同于另一台未安装Xcode的Mac验收。

## 包与安装方式

- `dist/YeShunguangPet-0.1.1-macOS-arm64.dmg`：只读压缩磁盘映像，含App、指向`/Applications`的快捷入口、安装说明和开源/素材说明。
- 同名ZIP为备用格式，解压后进入同名目录，包含相同安装材料。
- 两种包各自附SHA-256文件，只写文件名，便于在下载目录核对。
- App自带PetCore、旧皮肤、ICNS图标和Notices。ICO原图来自原仓库，256×256，大图标为缩放。
- ad-hoc签名、未公证。DMG打包与签名校验不代表苹果已认可开发者；网上下载后可能需要按Apple说明手动允许。

## 真实验证结果

| 检查 | 结果与范围 |
| --- | --- |
| 原有XCTest | 基线与改动后均30 core + 10 AppKit，共40项、0失败，TEST SUCCEEDED |
| 分发集成测试 | 3项通过；使用实际复制的App、系统打包/签名/挂载命令，没有mock系统工具 |
| DMG与ZIP | 真实生成、SHA-256核对；只读挂载DMG；原生ditto解压ZIP；检查说明、图标、许可及完整App签名 |
| 搬离工程目录运行 | 从DMG复制到独立临时目录`模拟应用程序/叶瞬光桌宠.app`；弹出源DMG后启动；cwd在临时目录，PATH仅/usr/bin:/bin，DEVELOPER_DIR指向不存在路径，未继承DYLD环境 |
| 动画/保存/退出 | 默认随包旧皮肤进入visible运行态，frameUpdates>0；SIGTERM进入正常终止，退出0，隔离配置写入 |
| 二次启动恢复 | 在隔离配置中设置一个与初始位置不同的有效位置，启动后退出；保存的实际窗口位置与输入一致。此项验证配置恢复，不代替真实鼠标拖动测试 |
| 非便携依赖拒绝 | 真实install_name_tool把框架依赖改为开发机绝对路径，再重新签名；旧打包脚本错误接受（RED），新脚本拒绝且不输出安装包（GREEN） |
| 显式App路径 | 旧smoke脚本忽略--app，会误启动工程App（RED）；现在缺失显式路径立即失败（GREEN） |
| 真实资源 | 旧JSON/PNG原SHA-256保持一致；主程序和框架仅arm64；所有依赖为随包PetCore或系统路径 |

原始日志在`.build/distribution-validation/`：`baseline-tests.log`、`final-xctest.log`、`packaging-red.log`、`smoke-red.log`、`packaging-final.log`、`build.log`。最终构建来源见App内`Contents/Resources/build-info.json`，最终包和校验和位于dist。

## 遇到的工具差异

- iconutil在受限沙箱中对尺寸和文件名正确的iconset报告Invalid Iconset；完全相同输入在本机系统服务可访问时成功。没有把该环境失败计为产品回归RED。
- Python zipfile按CP437显示ditto ZIP的中文文件名，不能据此判断macOS解包失败。改为用原生ditto真实解包，再检查实际文件名与签名；目标Mac使用流程通过。
- 破坏依赖的负向用例会产生install_name_tool签名失效警告，这是测试预期；用例随后重新签名，证明拒绝原因是非便携依赖。

## 尚未验证

另一台未安装Xcode的Mac、macOS 15或其他版本、浏览器实际下载后带quarantine的Gatekeeper首开、公司管理策略、Intel、真实睡眠/Spaces/外屏场景均未测。应用程序目录的本机验证使用临时模拟目录，没有覆盖或安装到个人`/Applications`。

下一次外机验收应走：浏览器下载 → 安装到应用程序 → 按系统流程首次打开 → 动画和基本互动 → 菜单退出 → 重开恢复位置。不能以本机签名检查或搬移测试宣称此链路已经通过。

Apple官方首次打开说明：https://support.apple.com/zh-cn/102445

本次只做本地构建与提交；没有推送、打标签、公开发布或上传至苹果公证服务。
