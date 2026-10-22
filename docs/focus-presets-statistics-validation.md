# 0.1.18 快捷计时与今日统计验证

日期：2026-10-22。用户选择A＋C，确认“仅完整完成段的计划时长，包含睡眠”口径，并批准0.1.18会话短设计。本会话在独立Mac仓库原地开发，无额外工作树；本版仅本地交付，未授权push/tag/Release。

## 行为与存储

15/25/45/60分钟预设仅准备态可用，先保存常用时长再开始，休息时长不变；保存失败不启动。菜单与SwiftUI命令捕获状态代次，旧项不能在重置后重开。预设子菜单纳入既有菜单暂停集合。

只在FocusTimer发出一次专注完成事件时累计该段计划分钟，休息与未完成重置/退出不计。日期来自结算时本地Gregorian日期，睡眠到期在唤醒结算日计入。只存一个日期的汇总，界面根据当前日期投影；日历、时区或系统时钟变化刷新显示，不加每日轮询定时器、不按秒写盘。跨日显示0，下一完成段替换上一日期汇总。没有历史或实际清醒时长估算。

schema13在PetSettings顶层存focusStatistics，专用12结构迁移，旧偏好结构不变。统计有严格日期/整数/范围和容量检查；坏配置保护原字节。PetSession集中所有设置写入，携带最新统计；完成后保存失败保留待存汇总，普通设置保存/重试/正常退出可以再次提交，不重复增加。其他偏好仍保持既有先存后生效规则。

## 当前回归

- core-red.log：新统计模型缺失导致编译失败；core-green.log：130项Core通过，含累计、换日、时区日期键、非法日期/数值、12迁移和13严格保护。
- native-red.log：新控制器接口缺失导致编译失败；native-green.log：14项原生定向通过，包括四种预设、保存失败、旧命令、模态/睡眠/退出门控、专注一次累计、休息/未完成不计、跨日/时区、失败重试、其他写入路径、坏配置与独立控制器重开。
- native-final.log：完整323项原生（130Core/193Mac）通过，含启动owner读取和原生预设子菜单暂停集合；release-tests.log：13项离线发版通过。

Xcode运行器有系统linkd连接诊断；测试退出0且TEST SUCCEEDED。编译缺失不写作运行期失败。测试仅使用临时配置/皮肤，不改个人登录登记。

## 交付证据

最终结果如下；原始日志、包与个人备份只保存在忽略目录.build/focus-presets-statistics-validation，不提交或上传个人数据。

## 单次评审与候选包

单次独立只读评审4a824d5..a71193f未发现Critical/Important，发现一项Minor：专注页旧说明仍说重开只保留时长，与当天统计持久化不符。已仅修正该文案，未改计时/统计行为；native-review-fixed.log的323项原生和release-review-fixed.log的13项离线发版通过，没有独立二次评审。评审未判断渲染、实际计时、系统/物理输入、最终包/安装、强制结束耐久和远端操作；执行者分别核验交付，物理/系统/强制结束/远端限制继续保留，详见review-summary.json。

a71193f候选的10项分发、双架构包库存/签名/摘要、八附件离线检查和ARM搬移重开通过，已归档至review-initial；它不是文案修正后的最终交付来源。隔离探针真实60.051963秒完成一次，60个不同显示秒数、Focus调度器60次唤醒、额外573次100ms等待检查，汇总1次/1分钟落盘并由新控制器读取；不等于全进程仅60次唤醒。最终来源核验仍以之后的实际结果为准。

最初NSHostingView缓存PNG含透明背景，不能据此认定文字不可读或布局通过。探针显式补背景、设置colorScheme并在当前drawingAppearance中缓存后，已查看浅色准备态、深色完成态，预设/统计/错误区可读。该改动仅在忽略的探针中，不改产品视觉；保留initial-alpha-renders和render-recheck.log。原生缓存渲染不等于真实窗口截图、鼠标或焦点实测。

## 最终来源、运行与安装

最终干净来源a63be62227391ba3fc2a20b36adaf5c6a158dd14，trackedChanges=false，0.1.18/build19。之后交付记录提交只改文档，不改变App来源。

- 最终导出工程的10项分发测试通过（distribution.log），含schema1→13、统计2次/40分钟及全部偏好跨独立进程重开保留、素材缺失回退。两架构App/DMG/ZIP、签名、原素材、最低macOS15、动态依赖、符号链接、库存一致性和SHA-256核对通过。八附件prepare-release.py --check-only完全离线通过，没有创建草稿、标签或Release。
- ARM从DMG复制到中文/空格路径、弹出DMG后，在/private/tmp、剥离开发变量并设置无效DEVELOPER_DIR的环境启动、正常退出并重开恢复；仅本机搬移，不是外机或Gatekeeper首开。见package-verification.json和final-relocated-smoke.json。
- 最终来源的隔离Bundle由原生菜单开始15分钟预设、保存为常用时长，用注入时刻结算一次15分钟；休息不计、跨日投影0、写失败保旧字节及待存汇总、重试不重复均通过。另一段真实自定义1分钟耗时60.076829秒，显示60个不同秒数，完成1次/1计划分钟落盘，新控制器读取且处于准备态。Focus调度器60次唤醒，探针另有573次100ms等待检查，不宣称全进程只唤醒60次。15/25/45/60分钟的到期边界由注入时刻验证，不冒充四次真实长计时。
- 缓存12张最终原生画面，含浅/深色准备和完成、预设运行、换日、保存失败、紧凑完成及真实一分钟。已查看准备态/深色完成/错误区，以及520×380内容区的顶部和原生NSScrollView滚动到底部，说明可达；探针背景处理仅用于缓存，不能代替实际系统样式/焦点/物理滚轮。见native-probe.json/.log、minimum-render.log及PNG。
- 按准确路径正常退出旧0.1.17，备份旧App、退出前及退出后配置，再安装/Applications/YeShunguangPet.app。schema12→13保留全部原偏好、皮肤、迁移时位置、快捷键、时长、个人台词与计时窗状态，新增空日/0次/0分钟统计；正常启动和退出核对后移除验证环境变量，保持新版运行。未登记或撤销正式登录项。见local-install.json，备份previous-installed-0.1.17.app及personal-settings-migration-baseline.json只保留本机。
- 按已安装App的PID筛选在屏窗口几何，确认计时窗大小/显示状态符合保存偏好；不读取其他应用内容或推定跨应用焦点。见installed-window.json。

App：/Applications/YeShunguangPet.app。安装包：dist/YeShunguangPet-0.1.18-macOS-arm64.dmg，Intel实验包另标x86_64。完整来源/评审/包/安装汇总见final-source.json、review-summary.json、final-delivery.json、local-install.json及completion.json。

保持本地codex/macos-focus-presets-statistics，未合并main、推送、打标签或发布，云端未构建本版。用户整体体验、真实键鼠/焦点/系统睡眠与日期事件、Spaces/登录/热插拔、Intel/外机/Gatekeeper、强制结束/断电时未保存汇总的耐久仍未据本轮验证；明确继续退出或强制结束可能丢失尚未保存的增量。

真实键鼠、跨应用焦点、系统睡眠/Spaces/登录/热插拔、Intel/黑苹果、外机与Gatekeeper首开未由本轮自动回归验证；注入时间/通知与原生回调不代替系统实测。保持Windows仓库和Minimal Sleep只读。

## 用户验收与推送授权

用户随后在本会话反馈“验证通过，推送”，确认0.1.18快捷计时与今日统计版本的本机整体体验，授权按既有流程同步main和codex/macos-focus-presets-statistics。只做普通push，不触发prepare_release，不打标签或创建/发布Release。

该反馈不扩展为四种预设、所有计数/跨日/睡眠结算、保存失败/重开、物理输入或系统/Intel/外机场景均逐项实测；既有自动化边界继续保留。前述“待验收”“未推送”为本地交付时状态，远端和云端结果按本轮实际日志记录，未授权下一版产品实施。
