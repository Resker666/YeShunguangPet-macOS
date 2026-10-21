# 0.1.12 更新检查、快捷键与设置分组验证

日期：2026-10-21（Asia/Shanghai）。Mac mini M4 / macOS 27.0 / Xcode 27.0 / Swift 6，最低目标macOS 15.0。按用户批准的设计和计划在独立Mac仓库直接实施，未改Windows、Minimal Sleep或原始皮肤字节。本版仅本地开发，未推送、打标签或写入远端Release。

## 自动化与实际进程

- `bash scripts/test.sh`：213项通过，Core107、Mac106。相对0.1.11增加26项：Release纯模型4、快捷键模型2、迁移/保护3、更新客户端/取消4、快捷键控制器8、Carbon实际登记1、设置分组4。旧皮肤/互动/退出回归保留。
- `python3 -m unittest discover -s Tests/Release -v`：13项离线通过，没有正式Token或远端写入。
- 双架构`build-app.sh`通过；`python3 -m unittest discover -s Tests/Distribution -v`：10项通过。修改后的schema8断言先对保留0.1.11实际进程失败（7 != 8），再对新版通过；完整偏好、位置和UUID重开保留。
- ARM `smoke-app.py --check-restore`在隔离配置且无开发工具环境中启动、动画、正常退出和重开恢复通过；不修改个人Application Support。

原生日志见忽略目录`.build/update-shortcuts-settings-validation/`中的`native-tests.log`、`release-tests.log`、`distribution.log`、`smoke.json`；RED/GREEN与任务提交在本计划独有的`.superpowers/sdd/`记录。最终交付后长期摘要以本文件为准。

## 手动更新的证据

独立ad-hoc测试Bundle调用生产ReleaseUpdateClient/Model，2026-10-21T08:34:27Z实际匿名GET一次，返回HTTP200、公开最新版**0.1.11**和官方ARM DMG路径；与当前0.1.12比较为`ahead`，界面显示“当前开发版本高于公开版本，无需更新”。0.1.11是当时已存在的公开状态，本轮没有创建或发布它。

固定请求、无Token/Cookie、15/20秒、1 MiB声明及实际字节边界、异常HTTP/断网/超时、关窗/退出取消、底层Task取消和过期结果均有离线回归。真正公网成功仅指上述一次GET；未下载远端安装包，不把替身失败场景称为实际断网或限流。

## 原生页面与系统API

隔离测试Bundle通过原生Pasteboard将真实知更鸟ZIP送入生产控制器，先预览、不安装、不改变当前角色；切换五组保留candidate。五组视图、共用保存错误、旧登记恢复失败、8000字符说明和520×480窗口滚动均生成PNG并检查。后续离线重绘不会重复查询公网；首次实网证据为`native-probe-first.json`，重绘单独记录。

实际Carbon API在独立测试进程登记四修饰键+F12，第二独占登记按预期失败，解除后可再次登记和撤销。控制器的冲突、保存失败、恢复失败、部分解除失败、重试、重复按住、菜单/sheet/退出、旧ID事件使用登记器边界替身验证，角色命令仍调用真实PetSession。API成功和模拟事件不等于物理键盘触发。

整个测试未登记/撤销正式登录项，未设置个人快捷键或覆盖个人配置。视图创建、切页、回App刷新不发网络请求或重复登记。

## 交付状态与边界

本地交付已完成。独立只读评审覆盖fa64742..5b22437，Critical/Important/Minor均为0；包与个人App升级在评审之后实际核验，证据如下。

真实跨应用全局按键、输入焦点、Finder物理拖放、睡眠/Spaces/全屏、重新登录、Intel／黑苹果、其他Mac及网络下载后的Gatekeeper首开仍未验证。包继续为ad-hoc、未公证；其他人运行不需要Xcode，但首次系统拦截需按包内说明处理。

## 评审与实施判断

- 原gpt-6-astra评审因用量上限在最终结论前中断；改用可用的gpt-6.1-sol完成同一次全分支评审，不把中断时的阶段消息当结论。代价是模型判断能力可能不同；最终成功评审仍独立于实现者。
- 物理键盘/Finder/焦点、系统、Intel/其他Mac及Gatekeeper按既定范围保留手动待测；API和模拟不替代它们。如果边界判断不足，这些真实场景仍可能有缺陷。
- 标题栏选中Tab在NSView缓存PNG中呈黑色胶囊，缓存不能证明实际屏幕上选中文字的颜色；继续使用系统原生TabView样式，TODO补真实界面确认。若这不是缓存差异，实际选中文字可能暂不可读，需要按真实反馈修复。
- 干净包与个人App升级作为评审后的实际检查完成，不能用源码评审替代；如果省略这层检查，包内容或迁移错误可能遗漏。后续交付结果单独记录。

## 最终安装包与日用App

干净来源为`06817fa62993364e0a13fc4c594c2a33e20747d9`，两个架构build-info均为同一完整提交且trackedChanges=false；后续本次收尾提交仅更新文档。ARM和Intel各有DMG、ZIP及各自SHA-256，共八份文件，均在dist根目录。`verify-final.py`实际挂载两份DMG、解出两份ZIP，逐文件/链接核对与所构建App一致，签名和原素材哈希通过；ARM从已弹出源镜像的另一目录启动、正常退出、重开恢复位置通过。`prepare-release.py --check-only`对这八份最终附件、版本、来源和说明离线检查通过，未联系GitHub、创建草稿或发布。

| 架构 | DMG SHA-256 | ZIP SHA-256 |
| --- | --- | --- |
| arm64 | `2bf595bf9a20805296ff328b79baa358b57d0e16740d7e04ef2e3ffc048712fd` | `351b829efa8a1756849a5e58b0d5d0ea979b30f48b361dacdefe3e4cf853e304` |
| x86_64 | `fb015cb908a5a9a116fee01d50b70e72fcd59e795701a6aabc66b3fcd2fc6e75` | `6055e61b2060068a7550c15535737fc7d59ad53fef57d9adbe0716db7f3eee72` |

已按当时准确可执行路径核实并正常退出旧日用进程，备份旧App和退出后配置，再安装`/Applications/YeShunguangPet.app`的0.1.12/build13。个人schema7→8后原偏好、所选皮肤和更新时位置保留，keyboardShortcuts=[]；未登记/撤销正式登录项。安装后先做一次正常启动/退出核验，再正常启动留作体验；交付核验时运行PID为73086。PID只记录当时事实，后续操作必须重新核对路径。

回退备份为忽略目录中的`previous-installed-0.1.11.app`和`personal-settings-migration-baseline.json`，不属于Git提交。完整最终证据为`final-source.json`、`final-delivery.json`、`local-install.json`、`final-relocated-smoke.json`和对应日志。个人配置快照只在本机忽略目录，不加入仓库或安装包。

用户整体验收尚待确认；尤其真实跨应用全局按键、选中分组文字、既有系统场景、外机/Intel和Gatekeeper仍保留上述边界。当前开发分支保留为`codex/macos-update-shortcuts-settings`，本轮没有合并main、推送、打标签或写入远端Release。

## 推送授权与推送前核验

用户随后明确要求“推送，并且执行CA”，授权按既有流程同步main和codex/macos-update-shortcuts-settings；此为推送指令，未声明0.1.12整体验收通过，既有真实输入/界面与设备边界保留。推送前本机当前树213项原生（107Core/106Mac）与13项离线发版再次通过；远端main仍为fa64742且可快进。本次只做普通push，不触发prepare_release，不创建标签、草稿或公开发布。远端推送及Actions结果以实际命令和云端记录为准。
