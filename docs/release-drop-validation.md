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

当前先记录实施证据，最终原生/分发测试、评审、双架构包及本机安装结果在完成后补充。日志与探针均置于忽略的`.build/release-drop-validation/`。真实Finder拖入、GitHub草稿创建/上传、Intel实机、其他Mac及网络下载Gatekeeper首开不从本地回归推定通过。
