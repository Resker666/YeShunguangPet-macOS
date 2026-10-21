# 0.1.10 ZIP皮肤导入验证

2026-10-21（Asia/Shanghai）。用户选择A：在现有“选择→预览→导入并使用”流程增加ZIP，自动识别一套皮肤，支持常见外层文件夹，失败保留当前角色；同时补README的公开Release下载入口。当前独立仓库和本地分支`codex/macos-zip-skin-import`继续复用，不增加工作树。先本地交付，不自动推送或发布。

## 实现与范围

原SDK没有公开libarchive头文件，因此没有引入私有接口或外部依赖。用已有系统zlib处理Stored/Deflate，按[PKWARE ZIP格式](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)校验中央目录、本地头、32位数据描述符、路径和大小。支持UTF-8以及Unicode路径extra、根目录及常见外层目录；Finder的__MACOSX不会被选作皮肤。多份pet.json明确拒绝，不自动挑第一套。

限制为80 MiB输入、512条目、16层路径、64 MiB单文件与128 MiB总声明展开，JSON仍128 KiB。读取原ZIP受普通文件/非链接/读取字节上限保护；全部条目验证路径、类型、重复与父子冲突、记录一致性和非重叠。实际展开按每个声明长度逐块限制并计算CRC，包含无关文件和目录，不以声明大小代替实际检查。ZIP64、分卷、加密、其他算法和旧式非UTF-8名称先提示解压，首轮不承诺所有ZIP变体。

只把所选JSON/PNG写入权限0700的唯一临时目录，经现有严格皮肤加载器验证后立即清理；不在磁盘创建包内任意路径。SkinPackage保留验证时的字节和CGImage，来源临时路径只是来源记录，之后不再读取；删除/修改原ZIP不影响确认导入。原有SkinLibrary发布UUID副本、设置保存/回滚、取消与退出协调继续复用，配置schema7不变。

## 测试证据

新归档测试首次运行因测试夹具调用漏写with标签编译失败，单独存archive-fixture-compile.log，不计行为RED。修正后14项测试观察7处断言失败，均来自现有加载器拒绝有效ZIP（archive-red.log）。实现后首次编译发现Swift的独立guard条件需各标try，保存archive-implementation-compile.log；修正后14项通过。

补查目录载荷：声明为空的目录却携带Stored/Deflate数据，两种情况均先观察到“未抛错”的失败（archive-directory-red.log）；改为目录也逐块校验后通过。加入有效大体积文件/总量限制、唯一条目数量上限、损坏/尾随Deflate数据、Unicode路径extra、注释，以及AppKit预览→删除原ZIP→确认→重开、歧义包及取消不改当前角色/配置/皮肤库。完整177项原生（96 Core + 81 Mac）通过，日志native-first-green.log。系统linkd/Workspace诊断出现在测试输出，XCTest断言零失败，未把这些系统日志写作无日志告警。

## 评审修复

只读评审发现两项Important：普通退出没有等待ZIP预览临时文件清理；macOS系统bsdtar生成的合法`./`根目录条目被误拒。另有一项Minor：本地Unicode路径extra虽解析却未检查路径有效性/与中央记录一致。均接受并修复。

根目录/Unicode专项先观察4处断言失败（review-archive-red.log）；预览退出专项先观察pending标记、等待和清理错误丢失共3处失败（review-preview-red.log）。新增退出测试以真实加载配合可控I/O返回边界，未用延迟猜测后台时序；首次异步XCTest断言及内部错误类型的访问编译问题单独保留，不计行为RED。

修复后预览也参与原有hasPendingMutation/terminateLater等待，包含临时清理；即使预览取消，SkinImportCleanupError仍保留到退出协调。允许根目录占位符，但其目录类型、空载荷与CRC仍验证；本地存在Unicode路径extra时检查有效路径并与中央有效路径一致，仅中央存在Unicodeextra的合法包继续支持。完整181项（98 Core + 83 Mac）通过，见review-green-full.log。

精心构造的EOCD注释签名碰撞、无签名数据描述符CRC恰等于签名字值的极低概率兼容边界，本轮未承诺全面支持；不把这些边界写为已验证。常见ZIP的真实工具输出另做核验。

## 交付状态

修复后的干净源码提交为`d91d2afa40cf10d8225e7b6afa1a099753f200cb`，版本0.1.10 / build11；最终两架构App的build-info均指向该提交且trackedChanges=false。之后仅更新交付记录。只读窄范围复核确认三项均解决，未发现新增可行动问题；评审还独立观察到预览临时目录存在时pending=true，等待返回后目录已清理。

三套原始皮肤通过独立Python Stored/Deflate、macOS ditto以及系统bsdtar共四个真实归档验证，覆盖中文外层目录、Finder封装和./根目录。均经生产加载/安装/重载成功，JSON/PNG哈希与原始字节一致，临时目录已清理。真实胡桃ZIP还经SettingsModel预览/确认切换，预览前当前角色不变；渲染实际设置窗口并人工查看PNG，角色预览、导入/取消按钮和说明显示完整。这是程序化模型与原生视图测试，不是文件面板操作或物理鼠标验收。

文件面板验证最初因CUA自动审批使用额度失败未执行，用户要求继续后重试；原生窗口读取又发生timeoutReached（约22分钟）。两次独立探针都因无法操作面板而到期退出，未记作产品通过；此后停止重复调用，仅保留界面操作待用户体验。没有借其他UI技术绕过审批或读取其他应用。原生图形工具的限制不影响已完成的模型/素材/打包证据。

从干净修复提交重新导出副本，ARM/Intel Release构建、10项分发（46.342秒）、双架构DMG/ZIP打包和来源检查全部通过。原生181项已针对修复后代码跑完，构建阶段没有重复该套件。最终核对两个App/框架的签名、架构、依赖、素材和许可，4个安装包与4个校验文件摘要通过；DMG与ZIP中的App逐文件/符号链接一致，两个DMG只读挂载后弹出。ARM从DMG搬到项目外中文路径，在无开发工具环境下独立启动、保存、退出和重开恢复通过。没有宣称Intel实机、外机或网络下载Gatekeeper首开通过；本版没有新的云端运行。

个人0.1.9按准确可执行路径正常退出并备份；ARM版已安装到`/Applications/YeShunguangPet.app`，实际启动、正常退出后再次启动留供体验。schema7保持不变，原有全部偏好（含用户已启用的台词）、皮肤选择及更新时位置核对保留；未调用正式登录项登记或撤销。dist已复制最终两个App及8份安装/校验文件，旧版包继续保留。

证据位于忽略的`.build/zip-validation/`：review-green-full.log、rehearsal.json、各构建/分发日志、real-zips.json、model-import.json、preview-render.png、final-delivery.json、local-install.json和配置/App备份。本地交付时分支`codex/macos-zip-skin-import`仅本地提交，未推送、打标签或发布，文件面板与0.1.10用户整体验收待确认。

## 用户验收与推送授权

用户在文件面板中未看到隐藏的`.build`目录，已说明可按⌘⇧G前往示例ZIP所在完整路径；随后用户明确反馈“验证通过，推送”。据此记录0.1.10本机ZIP导入整体体验通过，并按既有流程同步main与`codex/macos-zip-skin-import`。本次反馈不扩展为取消、失败、重开等逐项操作均已实测，不将此前中断的文件面板自动化改写为通过；真实系统登录、睡眠、Spaces、外机与Intel实机保持原有未测状态。本次仅授权推送，标签和Release仍需新的明确指令。

推送前重新运行`bash scripts/test.sh`，xcodebuild退出0；98项Core与83项Mac测试逐项通过，共181项、零失败。日志保存于忽略的`.build/zip-validation/push-native.log`。本次验收记录只改文档，产品代码仍与已交付的d91d2af一致；推送后的云端构建、分发与产物状态以对应提交的Actions运行为准。
