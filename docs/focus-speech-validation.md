# 0.1.15 自定义台词与专注计时验证

设计和实施于2026-10-21至22日（Asia/Shanghai）。用户选择D＋F、手动衔接，并明确“设计好，你就执行，我睡觉了”，授权设计自审后本会话直接实施；不推送、打标签或发布。

设计：[合同](superpowers/specs/2026-10-21-macos-focus-custom-speech-design.md)；计划：[任务与接口](superpowers/plans/2026-10-21-macos-focus-custom-speech.md)。沿用独立Mac仓库，分支`codex/macos-focus-custom-speech`，基线`d837afb`。Windows与Minimal Sleep只读。

## 阶段证据

- 原生干净基线240项（110Core/130Mac）通过。
- 旧实现的schema10与v9迁移测试先出现5处期望断言失败；新纯类型/个人台词测试另记录缺API编译失败。实现后120Core通过，Task 1完整250项通过。
- 原生夹具首次缺少嵌套结构的MainActor标注，修正夹具后9项实际运行，有1项发现解除专注暂停时cancelInput清掉正在按下的鼠标，导致误播完成回应。已改为退出该暂停时仅重新调度，保留手动输入；9项通过，Task 2完整259项通过。
- 界面前先验证旧菜单缺失；新增草稿/API另记录编译RED。双菜单、共享专注页、关闭设置不停止、父子菜单跟踪、到期旧命令、个人草稿跨角色/切页/关窗、保存失败及退出门控等13项已通过。后续后台预览忙碌、真实sheet门控、快捷键暂停集合和坏配置默认计时补充后17项通过。
- 首次完整界面回归120Core/143Mac中，唯一失败为旧设置测试固定五组的断言；保留实际切页、手动更新及不自动联网检查，移除枚举列表的重复断言，结果以最终完整回归为准。
- 原始日志保存在忽略目录`.build/focus-speech-validation/`；逐任务完整输出、评审包及裁定从本计划独立`.superpowers/sdd/`工作目录归档到其中的`execution/`，随后清理本计划暂存工作目录。编译失败不记作产品行为断言失败。

## 实现边界

个人台词按清单ID，与皮肤副本UUID分开；同ID共用，四类整组覆盖。空数组保持静默，未覆盖依次使用皮肤和默认文案。应用才保存，坏配置保护、新写失败保留旧生效值；编辑草稿捕获ID与代次，换肤、切页及关窗不能误保存到新角色。

FocusTimer按单调期限计算，不逐秒递减或写盘；只手动衔接。FocusController在角色隐藏或未打开设置时仍存在，独立单次调度在无可见计时界面时仅安排阶段截止；只有活动专注页/菜单跟踪时最多每秒刷新。手动安静与临时专注暂停分开，完成或暂停不更改手动开关。完成若被隐藏、睡眠、安静、菜单、设置或鼠标操作阻挡，只保留完成状态，不积压重放。

## 最终回归与评审

- `bash scripts/test.sh`最终**270项（120Core/150Mac）通过**，`native-final.log`；两项评审修复后的定向20项通过，`review-fixes-green.log`。
- `python3 -m unittest discover -s Tests/Release -v`离线13项通过，`release-tests.log`。不使用正式Token或写GitHub。
- 最终干净导出中`python3 -m unittest discover -s Tests/Distribution -v`10项通过，`distribution.log`，包括独立进程配置与素材恢复。

单次独立只读评审范围`d837afb..66966cc`。原定gpt-6-astra因额度限制未产生评审，改由可用gpt-6.1-sol/xhigh完成同一次评审。结论为With fixes：0项Critical、2项Important、1项Minor。执行者逐项裁定并进行一次修复，不宣称独立二次评审。

| 发现 | 处理及证据 | 取舍 |
| --- | --- | --- |
| 到期先结算后，旧“暂停”操作可能按新状态启动休息 | 回归先复现失败；命令捕获种类及状态转换代次，原生旧sender保留原意、SwiftUI控制身份随转换变化；两个事件顺序及共享命令API通过 | 增加轻量命令身份；只在语义变化时增加代次，不随每秒刷新重建按钮 |
| 取消退出后，可见专注页未恢复倒计时刷新 | 回归先复现截止60而非11的调度错误；根据实际窗口与页面恢复显示消费者；专注/其他页/已关窗通过 | 必须以窗口实际可见状态为准，避免关闭设置后常驻秒级刷新 |
| README仍称两类完成台词仅校验 | 最终文档更正为四类均已接入，并说明显示门控 | 文档修正不改变已验证产品代码 |

`review-fixes-red.log`记录19项中的3处期望断言失败；`cancel-quit-green.log`、`review-fixes-green.log`及`native-final.log`记录修复结果。代码修复提交为`4430577ad50a8c4a4cbdd626fbf214cf4699d79e`。评审不裁定的物理输入、系统和外机行为继续未验证；包及安装由执行者另行实际核对，不从评审结果推断。

## 最终真实 Bundle 探针与界面

最终探针使用4430577的Mac源码及对应干净构建的PetCore，在独立ad-hoc Bundle内运行，临时配置/素材、无网络请求、无正式登录项修改、无个人配置写入。旧66966cc的先期验证单独保存在`review-initial/`，不作为修复后来源的交付证据。

- 叶瞬光、知更鸟、胡桃三套真实旧JSON/PNG加载成功；各自四类个人台词解析和请求、保存/重开恢复通过。图片保存在`real-skin-0/1/2.png`。
- 专注运行、暂停及最小窗口显示正常；个人台词展开后能滚动到四类编辑、应用/恢复与已保存条目，再到底部原设置；实际写入失败时提示原因，旧覆盖保留。已检查`focus-minimum.png`、`focus-paused-minimum.png`、`personal-editor-minimum.png`、`personal-editor-controls.png`、`personal-editor-bottom.png`、`personal-save-failure.png`。
- 原生菜单实际进入跟踪后退出，包含状态、开始、重置和设置入口。最终探针再次验证旧暂停不能越过完成边界启动休息、取消退出恢复可见时钟。
- 隐藏角色、关闭计时显示消费者，使用真实连续时钟实际等待**60.046秒**，专注只完成一次、仍隐藏、没有自动开始休息；该次FocusController调度器唤醒**1次**、完成后无挂起调度。探针自身为等待结果有100ms检查，此结果不代表全进程只有一次唤醒。

探针台词编辑器展开使用其自身窗口上的合成鼠标事件；Accessibility展开未成功，未记作通过。倒计时部分界面检查使用可注入时钟，真实一分钟另单独实测。原生控件缓存PNG中的选中Tab仍呈黑胶囊，沿用系统样式，不能推定屏幕上的实际文字不可读；留给用户体验时检查。以上均不等于物理键鼠、跨应用焦点或系统真实睡眠测试。结果见`native-probe.json`、`native-probe.log`及保留的探针源文件。

## 安装包及本机交付

从干净提交`4430577ad50a8c4a4cbdd626fbf214cf4699d79e`导出，`trackedChanges=false`；版本0.1.15/build16。后续最终提交仅整理文档，App与附件来源仍固定此提交。

- arm64与x86_64分别构建App、DMG/ZIP和SHA-256，共八份附件；架构、最低系统15.0、签名、动态依赖和随附原素材校验通过。
- 挂载两架构DMG、展开ZIP后，文件字节及符号链接库存分别与对应App一致；四个安装包摘要与校验文件一致。最终八附件`prepare-release.py --check-only`通过，未创建草稿、标签或Release。
- ARM从DMG复制到含中文和空格的临时路径，弹出DMG后从`/private/tmp`启动，剥离开发变量、使用无效DEVELOPER_DIR及隔离配置，正常退出并再次启动恢复成功。本机搬移不能证明外机或Gatekeeper首开通过。
- 按准确可执行路径正常退出/Applications中的旧0.1.14，备份旧App及退出后个人配置，再更新到0.1.15。首次迁移并退出核对schema9→10、全部既有偏好、所选皮肤、更新时位置（小于1点取整差）和快捷键保留；新增25/5分钟、空个人覆盖。最后移除验证指标变量重新启动，日用App保持运行，未调用正式登录项登记或撤销。

可体验App：`/Applications/YeShunguangPet.app`；可见安装包：`dist/YeShunguangPet-0.1.15-macOS-arm64.dmg`，Intel实验包同目录另标x86_64。旧App、迁移前后配置、完整结果及辅助脚本保存在忽略目录`.build/focus-speech-validation/`，其中个人配置备份不提交或上传。

具体证据：`final-source.json`、`package-verification.json`、`final-relocated-smoke.json`、`release-assets-check.json`、`final-delivery.json`及`local-install.json`。分支保留`codex/macos-focus-custom-speech`，未合并main、推送、打标签、创建草稿或公开发布。本机整体体验待用户有空确认，项目待办已保留。

## 验证边界

真实物理键鼠、跨应用焦点、系统睡眠/Spaces/登录、多屏热插拔、Intel/黑苹果、外机及Gatekeeper首开如未实际观察仍为未验证。测试和Bundle探针使用临时配置与素材，不改正式登录项。用户整体验收在交付后另行记录。

## 用户验收及推送授权

2026-10-22用户在本会话反馈“验证通过，推送”，确认本机个人台词与专注计时版本的整体体验，并授权按既有流程同步main和codex/macos-focus-custom-speech。只做普通push，不触发prepare_release、不创建标签、Release草稿或公开发布。

该整体反馈不扩展为每类台词、计时各状态、隐藏到期、失败/取消/重开或物理输入均逐项实测；真实系统睡眠、跨应用焦点、Spaces/登录/多屏、Intel/外机/Gatekeeper仍保留既有验证边界。此前“待用户体验”和“未推送”描述为本地交付时状态，后续远端与CI以实际结果另行记录。
