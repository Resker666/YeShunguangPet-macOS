# 日用设置验证记录

日期：2026-10-20，Mac mini M4 / macOS 27.0 / Xcode 27.0。版本0.1.3（build 4）。

## 本轮范围

用户批准在当前独立Mac仓库和分支直接实施：菜单栏“设置…”打开可关闭重开的SwiftUI窗口，角色大小50%–200%（5%步进）、置顶开关、版本与架构信息。修改即时生效并自动保存。设置窗口可接收键盘焦点，角色窗口继续采用透明、不可key/main的NSPanel。

配置统一保存位置及偏好，schemaVersion 2兼容读取旧版1；旧配置使用100%和置顶默认值，下次保存升级。无屏幕时仍可保存偏好；损坏、未知版本或非法偏好保持原文件，只有明确执行备份重置才解除保护。保存失败在菜单栏和设置窗口显示，支持重试。

本轮作为已有菜单、窗口、配置流程的有界扩展，沿用用户已认可的会话设计与直接实施方式；未新增工作树，未改动Windows或Minimal Sleep，未推送、打标签或发布。

## 自动验证

- `bash scripts/test.sh`：49项通过，34 Core + 15 Mac，退出0。日志`.build/settings-validation/native-final.log`。
- 测试先确认旧实现不能读取/迁移新偏好（2个Core测试共3处断言失败），不能恢复缩放/置顶或打开设置（2个Mac测试共6处断言失败）；实现后全套通过。对应`core-red.log`、`core-green.log`、`mac-red.log`。
- 覆盖旧配置迁移、偏好往返、非法数字/布尔/重复键/版本保护、写失败原字节保留、无屏幕保存；实际NSPanel尺寸和层级、负坐标与小屏越界限制、隐藏缩放不启动动画、暂停时钟续播、缩放中断拖动、绘制方向与透明、设置窗口关闭重用、保存失败和显式备份重置。
- `bash scripts/build-app.sh`及`bash scripts/build-app.sh x86_64`：Release构建及ad-hoc签名验证通过。日志`build-arm64.log`、`build-x86_64.log`。Intel仅交叉构建，未执行。
- `python3 scripts/smoke-app.py --check-restore`：打包ARM App在隔离配置、非工程工作目录、无开发工具环境中启动，实际动画绘帧、正常退出及二次位置恢复通过。日志`arm-smoke.log`、`arm-smoke.json`。

- `python3 -m unittest discover -s Tests/Distribution -v`：9项通过，退出0，39.571秒。包含真实DMG/ZIP挂载/解包/签名与通知、ARM/Intel架构拒绝与隔离、中文搬移路径启动和位置恢复，以及独立ARM进程四次启动验证旧位置迁移、默认偏好、150%大小（288×312点）及非置顶偏好的保留。日志`distribution.log`。窗口层级本身由Mac测试检查，跨进程测试不冒充真实遮挡观察。

最终产物将以本轮本地提交重新构建。构建提交、包内文件一致性、签名和最终独立启动结果保存在`.build/settings-validation/final-delivery.json`。原始日志保存在忽略的`.build/settings-validation/`，产物在忽略的`dist/`。

## 独立代码评审

独立只读评审检查了相对27a9344的本轮实现及测试，未发现Critical、Important或需要列出的Minor问题。评审确认配置保护、无屏幕保存、隐藏缩放和窗口复用路径一致；真实GUI、最终Release/包、系统场景仍需分别按证据判断，不以代码评审代替实测。

## 真实观察与限制

- 界面工具可读取0.1.3实际角色画面，旧皮肤方向与透明背景正常。
- 尝试使用界面工具读取系统菜单栏时返回`timeoutReached`（约143秒）；未取得设置窗口真实鼠标调节、键盘焦点或错误时表单布局的GUI证据。原生窗口测试的可见性、canBecomeKey和模型修改不算真实鼠标验收。
- 用户此前确认的拖动、单/双击、隐藏/显示和召回属于原版本反馈；本轮未冒充用户已体验新设置。
- Spaces、全屏、Stage Manager、锁屏、真实睡眠、外屏插拔，以及新版长时间CPU/RSS未重新实测。旧版十分钟基线不代表缩放版性能结果。
- Intel／黑苹果实际运行、另一台无Xcode的Mac及下载后的Gatekeeper首开未测。黑苹果验收继续保留在[项目待办](../TODO.md)。包仍为免费ad-hoc、未公证。

本轮曾有一次临时文档编辑Python脚本因标准输入编码报错，未更改文件，随后改用apply_patch完成；不是产品构建或测试失败。Xcode日志仍有系统AppIntents元数据跳过、linkd/StatusBar场景诊断，未导致测试失败。hdiutil在macOS 27显示弃用提示，挂载/弹出结果按实际退出码记录。
