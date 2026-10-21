# 0.1.11 发版草稿与拖拽导入

2026-10-21（Asia/Shanghai）。用户选择B、C：在现有CI中增加手动准备Release草稿，在既有皮肤预览/确认流程增加拖拽入口。继续在独立Mac仓库原地开发，分支`codex/macos-release-and-skin-drop`；不增加工作树，不改Windows或Minimal Sleep。版本0.1.11 / build12，配置仍为schema7，默认皮肤原字节不变。此次授权实施，未授权推送、打标签、创建远端草稿或发布。

## 拖拽入口

设置窗口使用原生NSHostingView拖放目的地，仅注册文件URL和复制操作；角色窗口不接收皮肤文件拖入。拖入单个本地ZIP、目录或JSON后复用SettingsModel.previewSkin，实际读取和归档校验仍在后台；不会直接切换或复制素材。预览确认、UUID副本、保存失败回滚及正常退出等待仍复用原逻辑。拒绝多项、网页链接、纯文本和不支持的文件类型。

选文件与拖放共用预览任务，任务排队时已阻止第二次拖入；窗口关闭及退出取消任务，已开始读取的操作仍由原hasPendingMutation协调清理。打开设置的皮肤库刷新与立即拖入曾复现竞争：刷新先开始导致已接受的拖入不预览。现改为已有预览任务时不抢先刷新，预览后再刷新列表；对应回归在修复前观察到三处失败。

最初针对设置窗口注册的回归观察到缺少原生fileURL目的地的断言失败。另有测试目标名、NSWindow/NSView属性混用、测试sheet同步重载、manifest参数及NSObject已有协议方法的问题；这些调用或夹具编译失败均独立保留日志，不记为产品行为RED。回归使用真实NSPasteboard、原生窗口、现有皮肤加载/安装和受控拖放协议边界，不能当作用户从Finder物理拖入或焦点实测。

## 发版草稿

现有macOS App工作流增加默认关闭的prepare_release布尔输入。普通push/PR继续只构建Artifacts；手动选择main且勾选后，完整检查通过才进入独立ubuntu-24.04草稿job。构建保持只读Token，只有草稿job申请contents:write；checkout固定本次构建完整提交，不持久化凭据，按upload-artifact返回的两个不可变产物ID下载，不按名字猜测旧包。

prepare-release.py使用Python标准库，先核对目录恰好八份普通文件、四个SHA-256、ZIP内版本和两份干净来源/架构。版本说明来自docs/release-notes/对应版本.md，草稿固定目标完整SHA。已有标签须指向该SHA，支持剥离annotated tag；脚本不创建或移动Git ref，不发布、删除Release，不覆盖已上传附件。已发布版本、来源或附件冲突均停止。同一构建的部分成功草稿可补传缺失附件；完成后的相同重试只读核对。最终从API检查八份附件的名称、大小、digest、uploaded状态以及草稿仍未发布。

离线测试先观察有效附件的检查命令因脚本尚不存在而失败，随后实现。另补数值0冒充布尔false的来源测试，先观察漏拒绝，再改为严格is False。GitHub请求只在外部边界使用替身，实际归档/哈希/版本/草稿决策均执行生产代码；另检查真实Request的上传域名、原始字节及凭据不泄漏。没有携带正式Token进行远端写入。

参考：[GitHub Release API](https://docs.github.com/en/rest/releases/releases#create-a-release)、[官方下载Artifact输入](https://github.com/actions/download-artifact)、本机公开AppKit NSDragging.h。下载action使用查阅时的v8，复用现有upload-artifact v7；新job的真实云端执行留待用户授权推送及手动准备草稿。

## 验证与交付状态

最终干净来源提交为`660a79e98fba178e7df026cabbdd5ac61789020b`；两架构build-info均记录该SHA与trackedChanges=false。后续仅补交付记录，产品/构建代码保持该提交一致。完整187项原生（98 Core + 89 Mac）通过，日志native-final.log；13项离线发版测试通过，日志release-final.log；actionlint退出0。原生输出仍有本机linkd/Workspace诊断，未写作“没有系统告警”。

本地执行实际CI的八个run步骤，全部退出0：环境、发版离线测试、ARM与Intel构建、10项分发（约54.6秒）、双架构打包、来源/校验拦截。原生套件已独立通过，没有在排练中再跑；没有执行云端上传或Release写入。实际metadata步骤还验证四种事件/分支/勾选组合，普通push勾选、非main手动勾选均失败，合法main手动勾选和普通push不勾选通过；见dispatch-gates.json。八份真实包另由prepare-release.py --check-only通过，不读取Token、不联系GitHub。

独立只读评审范围a5c3fd6..660a79e，Critical 0、Important 0、Minor 0，准予本地交付；评审独立重跑13项离线测试，查阅原生及静态检查证据，并核对官方API/action源码。未判断的真实Finder/焦点、云端草稿/发布、Intel/外机/Gatekeeper、登录/睡眠/Spaces/外屏以及强退/断电清理，均按既有合同或本轮未授权的外部操作保留为限制，没有静默删去。

用独立测试Bundle、隔离配置与真实NSPasteboard/控制器路径，依次预览并确认知更鸟、胡桃、叶瞬光ZIP。确认前当前角色不变，确认后原JSON/PNG哈希与参考相同；实际设置视图渲染为PNG并查看，预览图、说明、按钮及高亮无裁切。见real-drops.json、drop-preview-render.png。该探针不是Finder物理鼠标操作，未用界面工具超时的旧证据冒充本轮实测。

最终两份App与八份安装/校验文件分别核对签名、架构、依赖、许可、素材哈希和来源；DMG只读挂载后弹出，DMG与ZIP内逐文件/符号链接清单和构建App一致。ARM从DMG复制到项目外中文目录，剥离开发环境后独立启动、保存、正常退出和重开恢复通过。系统hdiutil弃用提示及测试刻意改依赖造成的签名提示保留在日志，分发断言零失败；没有宣称Intel实机、另一台Mac或网络下载Gatekeeper首开通过。

准确路径的个人0.1.10进程正常退出并备份，ARM0.1.11安装到`/Applications/YeShunguangPet.app`；实际启动/正常退出后再次启动留供体验。schema7、全部偏好（含已开启台词）、皮肤选择和更新时位置核对保留，没有登记/撤销正式登录项。根dist的两个App和八份文件均与最终导出构建一致；旧App与个人配置备份留在忽略的验证目录，旧版安装包继续保留。可见的`dist/皮肤示例/知更鸟.zip`与此前真实ZIP逐字节相同，便于用户从Finder体验。

完整证据位于忽略的`.build/release-drop-validation/`：native-final.log、release-final.log、dispatch-gates.json、rehearsal.json、real-drops.json、渲染PNG、final-delivery.json、release-assets-check.json及local-install.json。本地交付时仅本地提交，未推送、打标签、创建远端草稿或发布，用户整体验收及云端草稿写入待明确反馈/指令。

## 用户验收与推送授权

用户体验后明确反馈“验证通过，推送”，记录0.1.11本机拖拽导入整体体验通过，按既有流程同步main与codex/macos-release-and-skin-drop。此反馈不扩展为不同格式、取消/失败/重开等逐项操作均已实测，也不将原生回调测试改写为自动化真实鼠标通过；焦点、睡眠/Spaces、正式登录、Intel/外机等保持原验证状态。本次仅普通push，云端构建以对应提交Actions为准，不勾选prepare_release，不创建草稿、打标签或公开发布。

推送前重新运行完整原生187项（98 Core + 89 Mac）、发版离线13项与actionlint，均退出0；测试逐项零失败。证据保存于忽略的push-native.log、push-release-tests.log和push-actionlint.log。此次验收记录仅改文档，产品、测试及构建代码仍与已交付并评审的660a79e一致。
