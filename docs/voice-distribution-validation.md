# GitHub 独立语音资源分发验证

2026-10-29（Asia/Shanghai）。用户已认可设计和七项计划，本会话原地实施；具体资源同步/公开须待最终文件与正文审核后的明确指令。App保持0.7.0/build30，未操作个人App、已装引擎、聊天/记忆、Keychain或登录项。本文记录实际证据，不把本地结果写作公开下载完成。

## 单DMG可行性

原最终DMG为2,310,377,547字节，SHA256 `6a0229d6ef91ae2479e0a109dc269e1754cc3a522e002769952e889a53aaa020`。在新的忽略目录以UDZO、显式zlib level9、2个压缩任务转换，用时18.174秒，退出0；新DMG为2,052,866,765字节，距离2GiB上限尚有94,616,883字节。因首候选已达标，没有运行ULMO或采用分卷。

新容器SHA256 `75a586de07c813345f80c7b34c5d6788a86518d6c45996c569c37f4b5e89c895`。系统镜像校验成功；在本轮新建的中文/空格挂载目录只读核对全部28,828个payload文件、3,010,860,533字节、SHA256与执行位均匹配，无多余文件或链接。`engine.json`仍为原字节，SHA256 `c7a1a53bf9de6d45dc506901296a8946ce3c62d7b5b2079e0ab564640ee5d23d`；本次拥有的准确卷已正常弹出。原DMG与原清单再次哈希不变。没有调用语音推理或重新安装引擎。

转换和挂载命令产生当前系统的hdiutil弃用提示，但均实际退出0；未把提示改写为兼容故障。当前M4实际挂载和完整性通过不等于macOS14、其他M系列、Intel或外机Gatekeeper通过。

证据：忽略目录`.build/voice-distribution-validation/compression-result.json`、`compression-trial.py`与`logs/`。新候选暂存该目录，原始DMG、e1、实验与备份保留。此阶段未创建六附件成品、远端标签/草稿或公开发布。

## 初次六附件本地候选（已保留，最终候选另列）

已从干净工具来源`3382e44085cb6ac674a832d81fc3b1a9940bdb49`生成`dist/语音分发/voice-assets-v1.0.0/`，尚未上传。App兼容基线375ff36与上游b4570b8分别记录；App二进制仍0.7.0/build30，源码和普通八附件流程未改。

| 附件 | 字节数 | SHA256 |
| --- | ---: | --- |
| 引擎DMG | 2052866765 | `75a586de07c813345f80c7b34c5d6788a86518d6c45996c569c37f4b5e89c895` |
| 引擎DMG.sha256 | 115 | `26f4f9d3bca868a09b26e9625707df0dbecb173580db690148bc9c02de0bbac5` |
| 胡桃e1 ZIP | 160615265 | `4975c7524e726ac3165c5d8f3deededb6eba883ea2679960ddac8bb6cc33520c` |
| 胡桃ZIP.sha256 | 106 | `0425703c23cb98f8b26a142d0f605c6f58c6387e3a0401cf9c079c128a8ee343` |
| voice-assets.json | 4232 | `9090c0e1747df71f89cbf033bf4a47ee6e43083b98e433928a8626f374a224cf` |
| 安装说明.md | 2713 | `894e48a82facd8b52eca74971d286b5bb0ce1a9f146e48b2d143e3ffe3a26790` |

50项Release离线测试（含原13项App发版）及38项LocalVoice测试通过。新增测试用小PCM/假模型、假HTTP/API，不上传或访问真实凭据；默认/check-only路径不初始化认证客户端。覆盖严格六附件、64KiB小文件、ZIP路径/类型/CRC和三文件布局、PCM、保留源/拒绝覆盖、流式发送/中断/源变化、精确草稿补传/冲突/显式公开、匿名下载和Latest保护。普通App CI会自动发现新增Release测试，工作流与模型上传范围没有改变。

源包小文本的独立只读调查未发现当前用户实验目录、个人配置或凭据；发现的上游训练/CI路径与原来源资料一致，保留原字节。该调查只覆盖指定类型的小文本，不将其夸大为任意二进制内容检查。来源许可补充见`local-voice-resource-notices.md`；ERes checkpoint、G2PW内部对应及胡桃公开分发声明仍未核实，不写作已取得许可。

## 现有0.7.0实际兼容

六附件中的真实胡桃ZIP已解压到新的中文/空格目录，三文件目录无额外说明。优化Swift探针使用本机0.7.0构建的公开PetCore接口，在临时LocalVoice库实际完成`stage`、模型/参考音频SHA与PCM校验及`discard`，清理确认通过；没有访问个人音色库或发声。包contentID为`361099c24e5093c6a02d39f5919cf42959e405ee1e06c69a814d68bad406e271`。

最终六附件中的DMG在唯一中文/空格路径只读挂载，现有`LocalVoiceEnginePackage.preview`读取28,828文件及原manifest通过；另行用新的只读验证器逐文件核对全部SHA、大小与执行位，用时11.314秒。原生语音stage/discard及引擎preview合计1.312秒。本次记录的准确卷已弹出，没有操作既有挂载卷。证据为`.build/voice-distribution-validation/native-compatibility.json`、临时探针源码和同目录日志。

探针编译首次遇到受限默认模块缓存、随后发现分发App会剥离Swift Modules；改用本机同版构建目录的公开编译模块、独立可写module cache及分发App框架动态链接后编译/运行退出0。这是验证环境修正，不是产品功能RED或另一次App构建。App源码未变，未重跑597项原生测试、重新推理或替换日用App；仍不等于macOS14、外机、Gatekeeper或可闻体验专项通过。

50项Release和38项LocalVoice最终离线回归再次通过，真实六附件check-only通过。新增Git对象审计没有模型、录音或runtime，最大blob小于1MiB。具体候选发布正文已渲染到忽略目录`publication-body.md`，带完整工具提交及资源清单摘要标记。

## 唯一一次整体评审与修复

新gpt-6-astra/high只读评审覆盖375ff36..c8a0e9f，结果0 Critical、2 Important、1 Minor。两个Important经作者核实，均在同一次修复中完成RED→GREEN，没有第二次评审：

1. GitHub对附件名存在规范化行为，[官方API说明](https://docs.github.com/en/rest/releases/assets#upload-a-release-asset)及[上游维护者复现](https://github.com/softprops/action-gh-release/issues/542#issuecomment-4063661020)支持该风险。模拟重命名服务器让原中文独立说明在首次准备和补传时均失败；改为ASCII `voice-installation.md`后同一草稿、重试及公开流程通过。中文说明内容与六附件数量不变，不放宽远端冲突检查。原设计/计划的最小文件名修正已记录，最终具体公开审核仍保留。
2. 在ZIP创建前替换已验证的voice.json，或连同模型/参考音频替换为另一套内部一致的资料，原实现均错误接受。现对最初清单、模型与参考音频的长度/SHA固定预期，流式归档实际写入字节必须匹配。三个替换场景由原来的3个失败断言变为拒绝成功，失败只清理本次ZIP，源资料保留。没有证据表明初次真实候选发生该竞态。

修复后完整52项Release及38项LocalVoice通过。RED日志为`.superpowers/sdd/2026-10-29-macos-voice-distribution/final-review-fixes-red.log`（39项语音相关测试，4个失败断言），GREEN为同目录`final-review-fixes-green.log`（52项完整Release）。最终实际包须重新由干净工具提交生成，原候选不覆盖。

暂缓的Minor：远端冲突报错未列明附件名、Release ID或差异字段；拒绝覆盖的行为正确，但恢复操作需要手工查看六附件。本轮不增加第二次修复或评审，此项入TODO。

评审范围判断及代价：外部推送/标签/上传/云端CI/匿名下载仍须具体指令，可能遭遇认证或服务失败；普通App永久公开发行另行授权，当前用户仍依赖会过期的CI包；第三方再分发权利披露保持，技术评审不能证明法律充分性，公开后可能仍需澄清或撤下；macOS14/其他M系列/Intel引擎/Gatekeeper/可闻质量不据当前证据宣称通过，其他设备可能失败；任意DMG与源包对应依靠事先挂载验证，本候选已做，未来维护者误选另一镜像会产生错误来源；任意第三方ZIP解压器未逐个验证，当前生成包/macOS解压正确不保证所有工具一致；单操作者流程无法原子排除另一远端写入者，最后一次远端复核之后仍可能被其他人修改。这七项均已在本计划ledger逐一记录，没有静默略过。

最终公开指令后的上传/匿名回下载仍待完成。

## 最终冻结候选，待公开审核

最终干净工具来源`9c89d47d4f503a96084b78f92c154ef8762c17d8`，六附件位于`dist/语音分发/voice-assets-v1.0.0-final/`；原初次候选目录保留，不用于本次公开。

| 最终附件 | 字节数 | SHA256 |
| --- | ---: | --- |
| YeShunguangPet-Voice-hutao-pilot-e1.zip | 160615265 | `4975c7524e726ac3165c5d8f3deededb6eba883ea2679960ddac8bb6cc33520c` |
| YeShunguangPet-Voice-hutao-pilot-e1.zip.sha256 | 106 | `0425703c23cb98f8b26a142d0f605c6f58c6387e3a0401cf9c079c128a8ee343` |
| YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg | 2052866765 | `75a586de07c813345f80c7b34c5d6788a86518d6c45996c569c37f4b5e89c895` |
| YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg.sha256 | 115 | `26f4f9d3bca868a09b26e9625707df0dbecb173580db690148bc9c02de0bbac5` |
| voice-assets.json | 4232 | `a85b56073a8782f77db83cccfa73eea3de3763858b2136b640ea2e717d7ee317` |
| voice-installation.md | 2713 | `894e48a82facd8b52eca74971d286b5bb0ce1a9f146e48b2d143e3ffe3a26790` |

最终DMG与ZIP字节/SHA和初次候选完全相同；安装说明只改公开文件名，中文内容原字节保留。小清单因工具来源改为修复提交而更新。最终六附件离线check-only退出0；再次用真实最终ZIP/DMG执行原生stage/discard与preview，通过后另行全量SHA/执行位核验28,828文件，清单保持、准确自有卷已弹出。原生步骤0.935秒、逐文件摘要10.995秒，证据`final-native-compatibility.json`；不调用语音生成或个人App。

完整六文件大小/摘要与拟公开正文已保存`.build/voice-distribution-validation/final-publication-review.md`，实际API正文为`final-publication-body.md`。资源tag仍`voice-assets-v1.0.0`，预发布、非Latest。原始DMG/清单/e1模型/参考音频复核不变，新增Git对象均为小文本，没有模型/音频/runtime。Task6本地完成后保持Task7未完成，待具体推送并公开指令；没有创建远端标签、草稿或上传任何附件。

## 已授权同步；公开等待认证（2026-10-29）

用户在最终六附件/正文与来源未知项展示后，明确选择“推送代码并公开这份资源预发布”。普通快进原子推送已完成：main和codex/macos-voice-distribution均到6f802cd7b5164fd2dbdadc4bf19739bc6713016e；资源轻量标签voice-assets-v1.0.0准确指向9c89d47d4f503a96084b78f92c154ef8762c17d8。没有强推或改资源字节。

[主干CI40861117830](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40861117830)首轮成功；[开发分支40861117950](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40861117950)第二次成功。两路均597原生（192Core/405Mac）、52Release、38LocalVoice、17分发测试通过，arm64与x86_64构建/打包/来源核对/Artifacts上传成功，普通Release草稿步骤跳过。本轮只核对新云端日志和附件元数据，未另行下载App产物，不冒充本轮云端App回下载验证。

开发分支首次失败是未变化的LocalVoiceProcessTests.testReadyFloodOrTimeoutKeepsMainActorResponsiveAndKillsOnlyOwnedPID第25行：150ms启动窗口内心跳ticks=3未满足>3；Core192、新Release52/LocalVoice38均通过。相同提交的主干原生全通过；保留首次失败记录后，仅重跑失败job一次，原断言与全部后续步骤通过。没有修改产品或测试阈值，不把这次不稳定性藏掉；已列TODO后续处理。证据位于忽略目录push-verification.json、feature-ci-first-failure.json及main-cloud-log-evidence.json。

当前公开资源Release按tag读取仍404，六附件未上传、未公开、未匿名下载。终端没有GH_TOKEN/GITHUB_TOKEN或gh，现有GitHub连接器无Release写接口；Safari原生CUA选择被工具的URL访问规则终止，没有绕过或再读该页面。已提供现成CLI登录/网页发布接续文档，等待用户完成必要认证。此为能力/认证阻挡，不是再次请求发布许可；Task7保持未完成、ledger保留。

最后读取普通App Latest仍是v0.1.19，ID420471790、来源37a73f0cd163dbb172300d0df269a4b7575180b5。资源标签推送不等于Release公开，也没有另发App0.7.0。本次文档收尾不改变已验证程序/工具；仅Markdown提交使用[skip ci]避免再次构建相同程序，云端通过的实际来源仍为6f802cd，文档提交未另建App产物。最终匿名回下载和公开状态/完整来源/Latest核验将在认证接续后按原授权完成。
