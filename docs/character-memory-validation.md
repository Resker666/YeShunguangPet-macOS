# 0.3.0 角色长期记忆验证

日期：2026-10-23（Asia/Shanghai）。版本0.3.0/build25，Swift6/AppKit、macOS14+，本机Mac mini M4 / macOS27.0 / Xcode27.0。只本地交付，不推送、打标签或创建/发布Release。

功能基线为`2c15595bcf2b3795b2101b1771b8f21139f4ec88`；最终功能及两架构包的干净来源为`f3f2420ea0badee40ce15528f7ace7b03e725e7a`，两份build-info均为`trackedChanges:false`。文档收尾提交不改变包内来源。

## 行为与回归

显式提炼当前角色已保存的最近12轮与已有记忆，每批最多5条候选；来源来自冻结的本地用户原话，默认不选，编辑并勾选后保存才生效。每角色20条、每条200个UTF-16单元，NFC规范化后去重。已确认记忆进入普通聊天上下文并跨重开保留，同ID共用、不同ID隔离。v1原字节读取、明确保存才写v2；保存失败保留原有效值和已接受意图，只重试本地，不重复请求。

| 实际命令或检查 | 结果与证据范围 |
| --- | --- |
| `bash scripts/test.sh` | 400项、0失败（145Core/255Mac），`TEST SUCCEEDED`；新记忆模型、v1/v2、FIFO、客户端、控制器与原生页面用例实际执行 |
| `python3 -m unittest discover -s Tests/Release -v` | 13项、0失败，退出0；离线测试，不写GitHub |
| `bash scripts/build-app.sh arm64` / `x86_64` | 两者`BUILD SUCCEEDED`、退出0；分别单架构，版本/build/最低14.0及干净来源正确 |
| `bash scripts/package-app.sh arm64` / `x86_64` | 各自产出DMG/ZIP及两份SHA-256，退出0；验证签名、随包依赖、原素材、许可、库存及摘要 |
| `python3 -m unittest discover -s Tests/Distribution -v` | 13项、0失败，退出0；包括两架构最低系统门控、实际包、签名、中文目录安装及隔离重开 |
| `prepare-release.py --assets … --version 0.3.0 --commit f3f2420… --check-only` | 专用空暂存目录中的本次八份附件通过，退出0；没有创建远端草稿、标签或Release |
| 当前ARM DMG搬离工程 | 复制至`/private/tmp/叶瞬光 长期记忆 h_xb1sdz/YeShunguangPet.app`，弹出源DMG后执行`smoke-app.py --app … --check-restore`，退出0；可见动画、正常退出及位置恢复通过 |

搬移测试使用临时配置、仅系统PATH、无DYLD/Xcode环境，未依赖工程目录；仍是本机启动，不等于另一台未安装Xcode的Mac或互联网下载后的Gatekeeper验收。Intel仅交叉构建与包核验，本版未在Intel/Sonoma实机运行。

## 优化隔离探针和原生界面

`.build/character-memory-validation/build.json`登记同一功能SHA、71份生产Swift摘要及探针/二进制摘要，编译使用`-O -whole-module-optimization`。入口替换为隔离夹具，链接本次Release PetCore，使用真实AppKit控制器/窗口和叶瞬光、知更鸟、胡桃旧皮肤。它是优化同源探针，不是字节相同的分发二进制。

`native-probe.json`确认候选未勾选不保存、原快照来源、修改/确认/重开、20条容量、同ID共享与不同ID隔离、超过12轮后记忆保留、清历史保记忆/清记忆保历史、取消晚到拒收、确认保存失败后关窗重开仅本地重试，以及退出等待已接受写入。原聊天12轮重开、坏档案保护/重置、隐藏桌宠后聊天独立和取消退出不重启请求也通过。启动请求和凭据读取均为0，本地重试额外请求为0。

浅深色、四页、最小窗口及1200个UTF-16单元的长来源均已做AppKit缓存渲染；展开长来源后滚动到底部，保存入口可达。主执行者查看候选、深色已存记忆、最小窗口底部和长来源底部PNG。组合输入的按钮与action门控由原生程序化marked-text用例覆盖，不能当作真实中文输入法或物理键鼠验证。

网络和凭据均为假实现，没有读取个人聊天档案、正式钥匙串或发送真实提炼请求。用户此前对0.1.22真实聊天的认可不代替0.3.0长期记忆提炼验收。

## 评审与流程记录

最终整体只读评审使用同一独立席位（gpt-6-astra/high），范围`2c15595..f3f2420`；第一次因额度中断没有产生结论，恢复后继续同一次评审。结果为0 Critical / 0 Important / 2 Minor，可进入交付；没有第二次独立评审，也没有评审后的生产源码修改。

主执行者按receiving-code-review流程对照源码确认两项Minor，按本轮非阻断项处理方式记录并延后：

1. 编辑已有记忆但未保存时，清空聊天历史成功，或开始退出后取消退出，编辑框仍保留旧草稿。设计原定这些时机应清掉；不会自动写入或改变已确认记忆，可点「取消编辑」或关窗清除。
2. 普通回答中途停止后再提炼记忆，旧的部分回复会误标「生成中」。回答实际没有恢复请求，片段也不进入完整历史；标签应进一步区分请求种类。

上述偏差见TODO，不能写作零已知问题。代价是0.3.0暂留两处界面/草稿寿命不一致；数据保护、显式确认、保存与本地重试未被这两项影响。

Tasks1–6均记录计划内RED→GREEN（新API缺失编译失败，再实现并通过对应回归）；没有隐藏这些日志。分发负向用例会故意修改依赖并重新签名，系统工具的签名警告属于该用例预期。hdiutil在本机给出弃用提示，实际挂载/弹出成功。

流程判断：为优化探针提供PetCore和资源，ARM Release先于最终评审构建。只在最终功能SHA不变时复用；若评审产生源码修复则重新构建及验证。代价是修复时额外构建，不交付旧来源产物。最终评审开始前的Intel打包请求曾因自动审批服务额度耗尽而未执行；恢复后使用同一审批入口重试成功，没有绕过检查。

## 本地安装与用户验收

已按准确路径正常退出`/Applications/YeShunguangPet.app`的0.1.22/build23，退出等待完成后，备份旧App、主配置和完整AI目录，再安装本次0.3.0/build25 ARM包。安装库存与干净源App一致，签名/版本/最低系统验证通过。以个人主配置正常启动、正常退出核对后再次启动，当前留在运行；仅本App的PID/窗口元数据检查显示4个自有窗口、其中2个在屏。

主schema13→13；所有非placement主配置字段相同，包含原偏好、所选皮肤、快捷键、计时窗、时长及统计；退出时位置按小于1个逻辑点容差保留。AI文件启动前后摘要一致，个人AI内容未解析/打印，未读正式Keychain、发送API请求或改登录项。安装期间会读主配置做字段比对；这不包含AI对话档案。自动安装过程未打开聊天窗口或触发提炼。

备份位于忽略目录`.build/character-memory-validation/previous-installed-0.1.22.app`、`personal-settings-after-old-quit.json`及`personal-AI-backup/`；目录权限0700，不进入Git。`local-install.json`只记录来源、版本、PID和校验布尔值，不放私人对话。

待用户在新App「聊天 → 记忆」体验：已有完整对话后点击提炼，查看来源、修改并勾选后保存；重开确认记忆仍在，再聊天检查角色能否参考记忆。不提供或发送密钥到聊天工具。

真实DeepSeek提炼、正式钥匙串提示、物理中文输入法/焦点、睡眠/Spaces/外屏、Gatekeeper与本版Intel/Sonoma实机继续标记未测。

## 本地证据

原始记录在忽略目录`.build/character-memory-validation/`：完整原生/离线发版/分发日志、两架构构建及打包日志、八附件暂存与离线检查、`final-delivery.json`、`moved-smoke.json`、优化探针与渲染PNG、`final-code-review.md`、`local-install.json`、`installed-window.json`。仅当前计划ledger及任务证据收尾归档到同目录`sdd-evidence/`，不删除其他计划工作区。

ARM App：`dist/YeShunguangPet.app`；Intel App：`dist/x86_64/YeShunguangPet.app`。本次八份附件前缀为`dist/YeShunguangPet-0.3.0-macOS-`，均ad-hoc、未公证。

## 后续普通推送授权

用户在本地交付后明确「推送」，授权按既有流程快进同步main和codex/macos-character-memory、核对两路CI及双架构Artifacts；不触发prepare_release、不打标签或发布。该指令不记作真实提炼验收通过。已验证功能来源仍为f3f2420，后续仅同步文档，不重复无变化的本地测试；云端会按实际推送SHA重新构建，不能混同本地包来源。远端提交、两路运行ID、检查数量及附件元数据的实际结果保存于忽略目录.build/character-memory-validation/push-verification.json。
