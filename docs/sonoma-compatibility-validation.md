# 0.1.19 macOS 14兼容记录

日期：2026-10-22（Asia/Shanghai）。用户确认按前述范围修改，继续独立Mac仓库原地开发；最初本地交付，随后按授权推送并完成云端核验。最新用户反馈：本台Sonoma14.8.9 / Intel Core i5黑苹果整体体验通过。标签及Release仍未授权，本次反馈记录仅本地提交。

## 原因与范围

用户黑苹果截图显示macOS Sonoma 14.8.9、2.11 GHz四核Intel Core i5、16 GB内存。0.1.11 x86_64打开时提示系统版本不兼容；检查该版及本地0.1.18均声明最低15.0，当前App和PetCore的Mach-O也实际要求15.0。截图中的机型识别不作为真实硬件型号，不记录序列号。

0.1.19/build20将App、PetCore及测试目标的Debug/Release共八处部署目标和App声明统一为14.0，不改变运行行为、原素材或schema13。打包校验器核对架构、macOS平台及两个Mach-O的实际最低系统版本，继续检查签名、系统依赖和原素材。安装说明、README及黑苹果待办同步更新。

## 证据与限制

- 本地SDK27.0支持macOS14.0部署及x86_64；只读API核验未发现必须15+的调用。双参数SwiftUI onChange要求14.0，SMAppService与ContinuousClock要求13.0。该检查不代替编译和运行。
- 新增分发回归先复现：签名有效的主程序或框架改为要求macOS16，旧校验器仍接受；现有ARM/Intel包也不满足14.0要求。三项测试产生四处预期断言失败，记录于忽略目录`.build/sonoma-compatibility-validation/deployment-red.log`。
- 323项原生测试（130 Core/193 Mac）和13项离线发版测试通过；两架构实际Mach-O均为macOS14.0。最终完整分发回归13项通过（47.630秒），包含新增3项版本校验和原有打包、搬移及配置重开检查。
- 交付当时Sonoma/Intel仍待实机验证；用户后续已确认本台黑苹果整体体验通过，见文末反馈。真实鼠标/焦点、睡眠/Spaces、多屏、重新登录、Gatekeeper及未装Xcode等未逐项确认的场景继续待测，不从本机M4运行、云端回归或单台整体反馈推定全部通过。

黑苹果手动验收见[步骤](intel-validation.md#黑苹果验收)。本轮未改Windows、Minimal Sleep或正式登录项。

## 干净产物与评审

- 本地开发分支`codex/macos-sonoma-compatibility`，干净App来源`5164ba909231f3e0e0959a2ba29207b169bfc402`，0.1.19/build20。后续交付文档提交不改变此App来源。
- 从该提交导出构建ARM/Intel App、DMG、ZIP及各自SHA-256，共八份附件；两架构build-info均为同一提交且`trackedChanges=false`。Info、主程序和PetCore最低14.0，架构、签名、动态依赖、原素材、包内库存与符号链接一致，摘要通过。八附件`prepare-release.py --check-only`完全离线通过，未写远端草稿。
- ARM从只读DMG复制至中文及空格路径、弹出源映像后，从`/private/tmp`以精简环境和无效DEVELOPER_DIR启动、动画、正常退出和重开恢复通过。Intel包只做交叉构建、签名与包检查，未执行。
- 单次独立只读评审`1e8dee0..5164ba9`无Critical/Important/Minor。最初评审因模型额度失败、没有产生评审；改用可用模型完成同一次评审，无独立二次评审。评审不证明Sonoma/Intel运行、物理输入、系统场景或下述单次位置偏移的原因。

## 一次位置恢复失败

第一次完整分发运行12项通过，DMG搬移启动后的坐标断言失败：实际为(75,206)，测试预期为(48,124)。该次临时目录已由测试清理，不能补足当时的全部事件证据；保留`distribution-first-failure.log`。

随后用持久隔离配置记录两次启动，正确恢复(48,124)；按原DMG搬移路径复测1项通过（15.260秒），完整13项重跑及最终包搬移重开均通过。原因仍未确认，没有归因于用户、系统或修改位置逻辑，也不把重跑当作已修复该现象。潜在的间歇位置问题保留给实际体验继续确认。

## 本机更新

按准确路径正常退出旧0.1.18，备份旧App和配置后，将0.1.19安装至`/Applications/YeShunguangPet.app`并保持运行。schema13→13，原偏好、选择的皮肤、退出时位置、快捷键、个人台词、时长、计时窗偏好及今日统计保留；没有登记或撤销正式登录项。自身PID窗口信息确认200×112紧凑计时窗在屏，与保存的模式/显示偏好一致，不记为物理输入或焦点验证。

安装前后完整记录及私有备份在忽略目录`.build/sonoma-compatibility-validation/`，包括`final-source.json`、`mach-o-requirements.json`、`package-verification.json`、`local-install.json`、`installed-window.json`及各测试日志。安装几何探针第一次误用`visible`字段而报KeyError，按实际`isVisible`字段更正后通过，仅属探针错误，未修改产品代码。

以上为本地交付阶段证据，当时用户整体体验及Sonoma/Intel均待验收、尚未推送。后续云端结果及本台用户反馈见下文；原始日志与安装包内容保留，不改写历史结果。

## 后续云端推送授权

用户随后明确要求推送到云端，以便黑苹果从GitHub项目下载；授权普通同步main及开发分支并核对Actions产物。本次没有声明本机或黑苹果体验已通过，未授权标签、Release草稿或公开发布。Actions成功运行页面提供x86_64安装产物，需登录GitHub，保留14天；下载外层ZIP解压后使用其中的DMG。实际远端、云端检查与下载核验结果另按日志记录，不把推送授权当作运行通过。

## 云端实际结果

`37a73f0cd163dbb172300d0df269a4b7575180b5`已同步main和开发分支；[main运行39743478929](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/39743478929)及[开发分支运行39743478912](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/39743478912)均成功。实际日志每路确认323项原生、13项离线发版、13项分发通过，两架构构建、打包、来源/摘要检查和产物上传成功，Release草稿job跳过。云端为macOS26.6.2 / Xcode26.6 / Swift6.3.3，实际编译目标均为macOS14.0。

实际下载开发分支Intel产物12410985491，核对外层与内层SHA-256、0.1.19/build20、同一完整提交、`trackedChanges=false`、x86_64、主程序/框架最低14.0、签名/原素材/依赖及DMG/ZIP库存一致；没有在M4执行Intel程序。证据在忽略目录`cloud-log-summary.json`、`push-verification.json`、`cloud-downloads/verification.json`。本次记录不重新生成或替换用户已验证的包，包内说明中的“未验证”是构建当时的证据快照。

## 用户黑苹果实机反馈

2026-10-22，用户收到本轮0.1.19 Intel云端下载入口后，在本会话明确反馈：“在黑苹果验证通过了”。结合先前设备截图，记录为Sonoma14.8.9、2.11 GHz四核Intel Core i5、16 GB内存这台黑苹果的用户整体体验通过。具体CPU SKU、实际下载Artifact ID及安装App内build-info未由本次反馈单独核对。

这补足本台机器的运行体验证据，不替代所有Intel/M系列Mac、其他macOS、Gatekeeper首开、无Xcode环境、睡眠/Spaces、焦点、多屏、登录、全部功能逐项验证或位置偏移根因分析。原始位置恢复单次失败仍保留，不能据此记为已修复。M4本版用户整体体验也不由黑苹果反馈代替。

本次仅更新本地验收记录和待办，尚未推送这些文档，也未打标签、创建草稿或发布Release。
