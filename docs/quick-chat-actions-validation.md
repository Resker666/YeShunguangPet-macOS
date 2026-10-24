# 0.4.0 桌面轻聊天与确认操作验证

日期：2026-10-24（Asia/Shanghai）。Swift6/AppKit，macOS14+；本机Mac mini M4 / macOS27.0 / Xcode27.0。功能基线b154e6bd347f858730ff171fc8a265abc8bd523b，最终功能、两架构包与日用App的干净来源aceefa64afe1f84d8c60d7627e4a8db72199de2c（文档收尾提交不改变包内来源）。版本0.4.0/build26，主schema13和角色档案v2保持。

这是本地开发与交付记录。没有推送、打标签、创建Release草稿或发布；真实DeepSeek/正式钥匙串、物理输入法/焦点/睡眠/Spaces、外机/Gatekeeper及本版Intel/Sonoma运行不由下述自动验证代替。

## 功能与实际回归

角色旁快速窗与完整窗共享控制器、草稿、选择、流式请求、操作候选与原有记忆资料。默认360×300，最小320×240，尺寸仅本次运行；跟随角色与屏幕事件，独立可key，隐藏桌宠仍可用。失焦保留、不自动取焦点，不增加轮询/新全局快捷键。交接只隐藏旧host，不作逻辑关闭；呈现代次拒绝旧host回调，真正关闭才撤销未接受内容。

DeepSeek每轮最多提出start_focus、pause_focus、resume_focus、set_quiet一项。参数严格验证，完整tool_calls+[DONE]才发布卡片。确认前尚未执行，不写历史；确认后按真实phase/status/时长/安静与ABA修订复核，消耗本地UUID并登记原角色执行意图，再调用既有计时/安静入口。开始专注先保存为常用时长；继续不能开始休息；手动安静与专注安静独立。

确认/取消结果为本地「App操作回执」，沿用完整user/assistant问答及原FIFO。已接受结果跨同步关窗、换角色与退出保存；执行后存盘失败只重试本地回执，丢弃不回滚操作，确认/重试不再请求模型或钥匙串。不承诺断电/强杀后的跨资源原子事务或跨进程exactly-once。

| 实际检查 | 结果 |
| --- | --- |
| `bash scripts/test.sh` | 427项，149Core/278Mac，0失败，TEST SUCCEEDED |
| `python3 -m unittest discover -s Tests/Release -v` | 13项，0失败，离线且无远端写入 |
| `bash scripts/build-app.sh arm64` / `x86_64` | 两者BUILD SUCCEEDED，单架构，0.4.0/build26，最低14.0 |
| 两架构`bash scripts/package-app.sh` | 各DMG、ZIP及两份SHA-256，挂载/签名/摘要检查通过 |
| `python3 -m unittest discover -s Tests/Distribution -v` | 13项，0失败；真实包/隔离搬移重开及负向依赖测试 |
| 八附件`prepare-release.py --check-only` | 退出0；两App同完整SHA且trackedChanges:false，两ZIP库存与源App一致，无远端写入 |

各任务均先写并运行RED，再实现GREEN；完整原日志保留。Task7集成回归真实发现修订在snapshot之后通知导致旧专注窗的新完成按钮过期；已恢复修订先于snapshot的原发布顺序，原失败FocusWindow用例及操作桥回归GREEN，随后全427项通过。桥观察仍延迟读取，未覆盖FocusMenus.onChange。

0.3.0两项Minor已直接复现并修复：成功清历史/开始后取消退出清理未保存记忆编辑，失败清空保留；提炼期间旧partial标未完成，不误标生成中。它们的旧版历史记录保留。

新增测试为显式假依赖；既有SkinSelectionTests actor-isolation、AppIntents元数据以及未托管AppKit场景日志仍存在。分发负向用例故意修改依赖并重新签名，签名警告为预期；hdiutil弃用提示不影响本轮实际挂载/弹出结果。

## 优化同源隔离与界面

`.build/quick-chat-actions-validation/build.json`记录生产Swift摘要、探针与二进制摘要、`-O -whole-module-optimization`完整命令。它链接本轮Release PetCore，替换入口并显式注入假网络/凭据，使用临时配置及三套真实旧素材（叶瞬光、知更鸟、胡桃）；不是与分发App字节相同的二进制，不是真实API验收。

`native-probe.json`通过实际专注开始/暂停/继续、常用时长保存、手动与专注安静独立、候选未确认零执行/零append、重复确认一次、ABA过期而秒数不失效、新草稿/选择/流式跨窗保留、回执写失败本地重试无额外执行/API/凭据读取、冻结记忆候选与回执共存、原生记忆编辑交接保留、同步关闭/同ID换肤/开始退出后原角色回执仍写入和退出等待、角色隔离/档案重开、隐藏桌宠后quick独立与原生marked-text门控。启动请求/凭据读取均0，正式Keychain和真实API操作均0。

主执行者查看浅深色最小窗的待确认卡、滚动到底后的确认/取消按钮、回执保存失败、普通轻聊天及原生完整页面PNG。最小卡片明确以document.visibleRect与按钮相交验证可滚动到达；长回复不撑大窗口，离底新分片不强制拉回。这些是AppKit缓存和合成输入证据，不是物理键鼠或屏幕截图实测。

## 最终评审、安装与剩余边界

同一最终独立席位gpt-6-astra/high只读完成b154e6b..aceefa6评审：0 Critical / 0 Important / 1 Minor，允许进入本地交付。首次因额度中断无结论，用户要求继续后恢复同一席位；没有第二次评审、评审后源代码修复或包来源变化。

延后的Minor：设置窗口文件选择sheet打开时，完整聊天内部「轻聊天…」直接调用协调器，可能先隐藏完整窗、再由轻窗全局门控拒绝显示，导致两窗暂时隐藏。请求/草稿仍保留，关闭sheet后通过菜单重开可恢复；不会自动操作、丢失已接受回执或写盘，因此按非阻断UI问题保留并进入TODO。后续应将此入口接到已有openQuickChat门控，并补此方向集成回归，不能将本版写作零已知问题。

评审未判定通过的三组边界：真实DeepSeek/正式钥匙串、物理IME/焦点/Spaces/睡眠及Intel实机、真实最小化/恢复。前两组明确不在自动验证范围；评审者的沙箱AppKit实验未达到最小化前置条件，既不能据此判通过，也不能据此认定缺陷。代价为真实环境的潜在兼容问题仍需用户体验。

ARM源DMG已只读复制到`/private/tmp/叶瞬光 轻聊天 c70t7qyi/YeShunguangPet.app`，弹出源DMG后以临时配置/系统PATH运行smoke-app.py --check-restore，退出0、可见动画/正常退出/位置恢复通过。仅为本机离工程启动，不等同外机、Gatekeeper或未安装Xcode的Intel验收。

按准确路径正常退出/Applications旧0.3.0/build25（PID24834），等待正常退出后，备份旧App、主配置与AI目录，再安装干净aceefa6的0.4.0/build26 ARM包。安装脚本已完成并写出成功报告；随后的shell输出包装误用了zsh只读变量status而退出1，未再次安装。独立核对运行PID30934的准确路径、安装库存与最终包一致、版本/架构，以及本App5个自有窗口/2个在屏，确认实际安装成功；包装错误不影响App或个人资料，原结果保留。

主schema13→13，全部非placement主字段/原偏好/皮肤/快捷键/专注时长/统计一致，更新时位置误差小于1逻辑点；AI文件启动前后摘要一致，没有解析/打印AI正文，安装器未调用正式Keychain、API或登录登记/撤销。旧包`previous-installed-0.3.0.app`、退出后主配置`personal-settings-after-old-quit.json`及盲复制AI备份`personal-AI-backup/`位于0700忽略证据目录，不进入Git。日用App现留在运行；本版真实操作与轻窗整体体验等待用户验收。

本轮流程取舍（完整代价）：

1. 复用每任务刚通过的精确测试结果，不对未变更源码重复同一测试；遵守开发者避免无依据重复的要求。代价为少一次重复采样，仍运行完整回归。
2. 将既有AppDelegate纳入未托管Mac测试，直接覆盖真实退出模态门控。代价为测试多编译一份生产源，不添加TEST_HOST或启动原入口。
3. ARM Release先于最终评审提供优化探针所需框架/资源；最终源码不变才复用。代价是评审若有修复须重建并重验，不能交付旧来源包。

证据均在忽略目录`.build/quick-chat-actions-validation/`；个人AI只在安装阶段盲复制和比较摘要，不能解析或打印正文。仅归档当前计划ledger，不删除其它计划工作区。

## 本地交付文件

ARM App：`/Applications/YeShunguangPet.app`，源码构建副本`dist/YeShunguangPet.app`。ARM安装包：`dist/YeShunguangPet-0.4.0-macOS-arm64.dmg`；Intel安装包：`dist/YeShunguangPet-0.4.0-macOS-x86_64.dmg`。同目录各有ZIP和SHA-256，本次八附件均ad-hoc、未公证。

当前仅本地分支`codex/macos-quick-chat-actions`；main/远端不变。验证日志、`final-delivery.json`、`native-probe.json`、`build.json`、PNG、`final-code-review.md`、`moved-smoke.json`、`local-install.json`和`installed-window.json`均在上述忽略目录，当前执行账本收尾归档为`sdd-evidence/`。

## 后续验收与普通推送授权

用户于2026-10-24明确「验证通过，推送」，确认本版在本机整体体验，授权按既有流程普通同步main及codex/macos-quick-chat-actions、检查两路CI与双架构Artifacts；不触发prepare_release、不打标签、创建草稿或发布。不能把整体反馈扩展为每个工具/失败/输入法/真实最小化/系统/Intel场景均已逐一验证；已知轻微项仍按TODO保留。

本地App与包来源仍为aceefa6。本次只追加验收及同步文档，不改变生产源码或重复已通过的本地检查；云端按本次实际推送提交重新构建。远端SHA、两路运行ID、真实日志检查数量和附件元数据以忽略目录push-verification.json/cloud日志为准，不以此授权段落代替成功结果。
