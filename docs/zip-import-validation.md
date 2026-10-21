# 0.1.10 ZIP皮肤导入验证

2026-10-21（Asia/Shanghai）。用户选择A：在现有“选择→预览→导入并使用”流程增加ZIP，自动识别一套皮肤，支持常见外层文件夹，失败保留当前角色；同时补README的公开Release下载入口。当前独立仓库和本地分支`codex/macos-zip-skin-import`继续复用，不增加工作树。先本地交付，不自动推送或发布。

## 实现与范围

原SDK没有公开libarchive头文件，因此没有引入私有接口或外部依赖。用已有系统zlib处理Stored/Deflate，按[PKWARE ZIP格式](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)校验中央目录、本地头、32位数据描述符、路径和大小。支持UTF-8以及Unicode路径extra、根目录及常见外层目录；Finder的__MACOSX不会被选作皮肤。多份pet.json明确拒绝，不自动挑第一套。

限制为80 MiB输入、512条目、16层路径、64 MiB单文件与128 MiB总声明展开，JSON仍128 KiB。读取原ZIP受普通文件/非链接/读取字节上限保护；全部条目验证路径、类型、重复与父子冲突、记录一致性和非重叠。实际展开按每个声明长度逐块限制并计算CRC，包含无关文件和目录，不以声明大小代替实际检查。ZIP64、分卷、加密、其他算法和旧式非UTF-8名称先提示解压，首轮不承诺所有ZIP变体。

只把所选JSON/PNG写入权限0700的唯一临时目录，经现有严格皮肤加载器验证后立即清理；不在磁盘创建包内任意路径。SkinPackage保留验证时的字节和CGImage，来源临时路径只是来源记录，之后不再读取；删除/修改原ZIP不影响确认导入。原有SkinLibrary发布UUID副本、设置保存/回滚、取消与退出协调继续复用，配置schema7不变。

## 测试证据

新归档测试首次运行因测试夹具调用漏写with标签编译失败，单独存archive-fixture-compile.log，不计行为RED。修正后14项测试观察7处断言失败，均来自现有加载器拒绝有效ZIP（archive-red.log）。实现后首次编译发现Swift的独立guard条件需各标try，保存archive-implementation-compile.log；修正后14项通过。

补查目录载荷：声明为空的目录却携带Stored/Deflate数据，两种情况均先观察到“未抛错”的失败（archive-directory-red.log）；改为目录也逐块校验后通过。加入有效大体积文件/总量限制、唯一条目数量上限、损坏/尾随Deflate数据、Unicode路径extra、注释，以及AppKit预览→删除原ZIP→确认→重开、歧义包及取消不改当前角色/配置/皮肤库。完整177项原生（96 Core + 81 Mac）通过，日志native-first-green.log。系统linkd/Workspace诊断出现在测试输出，XCTest断言零失败，未把这些系统日志写作无日志告警。

## 交付状态

只读评审、真实旧皮肤归档、原生文件面板和最终分发核验进行中。证据保存在忽略的`.build/zip-validation/`，产物最终放dist；0.1.10尚未推送或发布。Intel实机、真实系统场景与外机首开继续按原边界记录。
