# GitHub 独立语音资源分发 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 用户已指定本会话原地实施、不额外建工作树、不委派逐任务实现或评审；最后一次新的独立整体代码评审。只读事实调查可以独立进行。

**Goal:** 在现有GitHub项目交付可下载、可验证、可由0.7.0离线安装的独立引擎与胡桃e1资源，不把模型纳入Git或普通App包。

**Architecture:** 先在忽略目录实测完整引擎的无损DMG重压缩，再用独立Python工具整理六附件、严格小清单及胡桃ZIP。独立流式GitHub客户端与资源发版状态机只在明确命令下写入资源Release，普通App八附件流程与二进制不变。真实资源准备和一次整体评审完成后展示具体清单/正文，取得明确推送与公开指令，再执行并匿名下载复核。

**Tech Stack:** Python标准库（兼容现有本机/CI的python3，无新增依赖）、系统hdiutil/ditto、现有PetCore公开接口作隔离兼容探针；GitHub Releases REST API与现有用户登录能力。

**Spec:** `docs/superpowers/specs/2026-10-29-macos-voice-distribution-design.md`，用户于2026-10-29明确“认可设计，进入实施计划”。当前计划待审，不把设计批准写成产品/工具实施已批准。

## Global Constraints

- App保持0.7.0/build30、macOS14.0目标；引擎保持1.0.0、arm64、profile `gpt-sovits-v2proplus-cpu1`，e1保持`hutao-pilot-e1`及原三文件字节。主schema13、角色v2、voice1、日用App/引擎/AI/Keychain/登录项均不改。
- 单附件`0 < bytes < 2**31`，小清单上限64KiB、正文上限64KiB；文件须普通、非链接。引擎原清单6,897,725字节、28,828份payload/3,010,860,533字节，原DMG2,310,377,547字节；不能删内容或改权重来过上限。
- 原件只读：`dist/引擎包/YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg`、`.build/portable-voice-engine-validation/moved-inputs/final-engine-package`、`dist/语音包/胡桃-试用-e1`；新输出用`dist/语音分发/voice-assets-v1.0.0/`，实验与备份不移动，已有输出拒绝覆盖。
- 先UDZO level9，再按结果验证ULMO；不采用UDBZ、分段DMG、外部账号/付费托管、App下载/合并器。两种完整单DMG均未达标则记录实测并另行确认路线，不继续上传不可用附件。
- 六个公开附件：`YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg`及`.sha256`，`YeShunguangPet-Voice-hutao-pilot-e1.zip`及`.sha256`，`voice-assets.json`，`安装说明.md`。
- 资源预发布标签`voice-assets-v1.0.0`、名称“本地语音资源1.0.0（M系列预览）”、`prerelease=true`、`make_latest='false'`。发布工具完整提交、App兼容基线`375ff361e02de30f5ccab8a03e9f5b3412d44800`和引擎上游提交`b4570b876f5c086819ba84e3215472733c6a7b70`分别记录。
- 普通App CI只运行小夹具，不消费真实模型；现有`prepare-release.py`与普通App的八附件/≤256MiB合同保持。新增`Tests/Release/test_*.py`由既有发现命令自动执行，无需改工作流。
- 不读取私人AI/正式Keychain/私钥/令牌文件，不申请麦克风、不调用生成或朗读，不自动清除隔离属性。认证使用用户主动提供给受支持工具的登录/环境凭据，秘密不输出；无法认证则保留已校验结果并明确待用户操作。
- 未核实模型/素材权利按事实列出，不统一冒称MIT。Tasks1–6本地连续实施；最终推送、标签/草稿上传和公开发布只在具体附件及正文可审后按明确指令执行。计划获准后仅建立`.superpowers/sdd/2026-10-29-macos-voice-distribution/`，不恢复已完成计划。

## Review Focus

1. 打包后文件被替换或上传中变化：Task2/3检查文件身份、长度与实际发送摘要，冲突不得变成成功或公开。
2. 网络中断后同名附件已存在但状态为starter、部分上传或来源不同：Task4报告精确冲突，保留已完成项，不删改、不重复创建Release。
3. 胡桃ZIP解压后说明落进严格三文件目录，或出现重复/链接/穿越路径：Task2/6必须拒绝并用现有PetCore接口证明可导入。
4. 资源预发布污染普通App Latest，或下载说明错误指向不支持语音的旧App：Task4/5/7保持prerelease/非Latest，明确需要0.7.0；不把旧v0.1.19或14天CI地址当长期兼容App发行。
5. 工具只验证摘要却没有核实目标Release/标签/草稿状态：Task4/7重新读取精确远端来源、全部附件及公开状态；未发布或认证失败不得报告公开下载通过。

## File Structure / Shared Contracts

- 新建`tools/voice_distribution.py`：纯只读引擎清单验证、受限胡桃ZIP、六附件小清单生成/校验；不import ML、不调用会chmod/重写源的`write_engine_manifest`或会启动解释器的probe。可复用原`digest`/路径规则的思路，不能把写入器当验证器。
- 新建`tools/package-voice-assets.py`：开发侧显式入口，选用Task1实测通过的压缩格式、创建独立输出并写摘要/小清单；已有`package-local-voice-engine.py`原行为保持。
- 新建`tools/voice_release.py`：有界JSON/固定GitHub主机、流式上传/下载、标签及Release状态机；新建`scripts/prepare-voice-release.py`：`--assets --version --commit --notes`及互斥`--check-only`（默认）、`--prepare-draft`、`--publish`。离线分支不读认证环境、不联网；真实写入必须显式模式。
- 新建`Tests/Release/voice_fixtures.py`与`test_voice_assets.py`、`test_voice_transport.py`、`test_voice_release.py`；用小PCM/假模型、临时目录、假连接/API和稀疏大小边界，禁止真实权重或认证。
- 新建`docs/local-voice-downloads.md`、`docs/release-notes/voice-assets-v1.0.0.md`、`docs/voice-distribution-validation.md`，补充现有`docs/local-voice-engine-model-notices.md`、`docs/local-voice-engine-installation.md`、`README.md`与`TODO.md`。发布前状态必须写“待发布”，不能提前宣称链接可用。
- `AssetRecord(name:str,path:Path,bytes:int,sha256:str)`与`VoiceBundle(version:str,tools_commit:str,manifest:dict,assets:tuple[AssetRecord,...])`为冻结数据值；实现兼容当前python3。所有工具使用同一字段与附件命名，清单不写自身摘要。
- 核心接口：`verify_engine_tree(folder:Path, *, expected_manifest_sha256:str) -> dict`；`build_voice_zip(source:Path, output:Path, *, notices:Path) -> Path`；`build_bundle(engine_dmg:Path, voice_zip:Path, output:Path, *, tools_commit:str, app_commit:str, readme:Path, provenance:dict) -> VoiceBundle`；`read_bundle(folder:Path, *, version:str, tools_commit:str) -> VoiceBundle`。
- 传输接口：`VoiceGitHub(repository:str, token:str, *, connection_factory, progress)`，`request(method:str, path:str, payload:dict|None=None, asset:AssetRecord|None=None) -> dict|list`；`prepare_voice_release(api, bundle:VoiceBundle, notes:str) -> dict`；`publish_voice_release(api, bundle:VoiceBundle, notes:str) -> dict`；`verify_public_downloads(bundle:VoiceBundle, release:dict, destination:Path, *, opener) -> dict`。`connection_factory`、匿名下载`opener`与`progress(sent:int,total:int)`可注入且具有生产默认值；纯元数据假API实现同一`request`接口。所有可执行工具均在Task6整体评审前完成，Task7只调用已评审接口及更新事实文档。

---

### Task 1: 实测单DMG可行性，保留相同引擎内容

**Files:** 只写忽略目录`.build/voice-distribution-validation/{compression,logs}/`及`docs/voice-distribution-validation.md`，此任务不改产品或新增发布工具。
**Interfaces:** 消费Global Constraints三个原件；产出`compression-result.json`，含格式/字节数/容器SHA/原清单SHA/逐文件及执行位校验结果和准确自有挂载卷。后续只采用真实通过的候选。

- [ ] **Step 1:** 核对原DMG和最终源清单身份，确认原件`bytes==2310377547`、`bytes>=2**31`、manifest SHA为`c7a1a53bf9de6d45dc506901296a8946ce3c62d7b5b2079e0ab564640ee5d23d`；保存读取前记录，不把这个既有超限当新工具RED。
- [ ] **Step 2:** 用参数数组执行`hdiutil convert <原DMG> -format UDZO -imagekey zlib-level=9 -o <新候选>`，拒绝覆盖。若仍超限，另建ULMO候选；逐一记录体积、耗时、格式、退出值和真实失败，不并发运行重压缩。
- [ ] **Step 3:** 对选定`0<bytes<2**31`的候选`hdiutil verify`，以唯一新挂载点只读挂载；读取实际引擎目录，逐文件核对清单/大小/SHA/执行位与原`engine.json`，随后只弹出此次拥有的准确卷。不得弹出用户之前的卷。
- [ ] **Step 4:** 写可复查的实测记录；两种均不能达标则保留候选/日志，继续不依赖托管大小的本地准备，并先就真实失败确认路线，不写可发布结论。成功则把选定格式作为Task2精确参数。
- [ ] **Step 5:** 仅提交验证文档，原DMG/源包/候选均不入Git；提交`docs: record single image voice distribution feasibility`。

### Task 2: 六附件打包与严格离线校验

**Files:** 创建`tools/voice_distribution.py`、`tools/package-voice-assets.py`及`Tests/Release/voice_fixtures.py`、`test_voice_assets.py`；补必要的打包说明。
**Interfaces:** 实现Shared Contracts的四个打包/读取函数与两个数据值；Task3/4只消费`read_bundle`返回的快照，不重复定义附件合同。

- [ ] **Step 1:** 写失败测试：`test_bundle_requires_exact_six_files_and_full_provenance`断言六名、40位工具/App来源分离、语义版本/固定profile/架构；`test_asset_size_is_strictly_below_two_gib`断言0和`2**31`拒绝、`2**31-1`边界合法且先检查大小；`test_voice_zip_preserves_exact_three_file_package`断言ZIP内`胡桃-试用-e1/`只有原三文件，来源说明位于外层。
- [ ] **Step 2:** 运行`python3 -m unittest discover -s Tests/Release -p test_voice_assets.py -v`，观察新模块缺失或具体断言RED；不以环境故障记RED。
- [ ] **Step 3:** 实现只读有界JSON与engine清单验证、流式SHA、同一源文件身份前后核对、保留执行位；ZIP拒绝绝对/穿越/重复/链接/特殊文件、坏CRC/大小/摘要及多余条目。小清单只记录两份大包SHA、来源/兼容/说明，不生成循环摘要。CLI先在独立stage生成完整输出，成功才提交目录，失败只清本次stage、拒绝覆盖目标。
- [ ] **Step 4:** 补`test_rejects_changed_source_or_manifest_without_modifying_original`、`test_rejects_unsafe_zip_entries_and_inner_notice`、`test_failed_output_keeps_originals_and_existing_destination`；运行同命令，全部GREEN，源hash/权限与失败前一致。夹具只用假模型与合法小PCM，不加载pickle/torch。
- [ ] **Step 5:** 提交`feat: package and validate independent voice release assets`。

### Task 3: 有界流式GitHub传输

**Files:** 创建`tools/voice_release.py`传输部分及`Tests/Release/test_voice_transport.py`。
**Interfaces:** 实现`VoiceGitHub.request`，消费Task2的`AssetRecord`；支持元数据GET/POST/PATCH与固定`uploads.github.com`附件POST，正文有界、文件以≤1MiB块发送，进度回调可注入。

- [ ] **Step 1:** 写失败测试`test_upload_streams_bounded_chunks_and_exact_content_length`（假文件拒绝无界read，fake send最大块≤1MiB，长度/发送摘要相同）；`test_upload_failure_reports_state_without_retrying_post`（中断只调用一次POST）；`test_never_forwards_credentials_to_redirect_or_untrusted_upload_host`（拒绝跳转，不将token发往响应给出的任意URL）。
- [ ] **Step 2:** 运行`python3 -m unittest discover -s Tests/Release -p test_voice_transport.py -v`，确认具体RED。
- [ ] **Step 3:** 用标准库HTTPS连接、固定主机与安全repository/path、HTTP空闲超时60秒、有界JSON响应1MiB与适当错误类型实现；上传整体允许随持续进度运行，不能沿用旧120秒全请求预算或`asset.read_bytes()`。发送前后核对同一文件身份、长度、实际发送SHA，失败不写成功状态；异常不输出token/签名URL/任意服务端正文。
- [ ] **Step 4:** 补`test_source_replaced_or_changed_during_send_is_not_success`、`test_timeout_or_oversized_json_is_bounded`，同命令GREEN；用假慢流证明未设置固定120秒总上传中断规则，不做真实网络测试。
- [ ] **Step 5:** 提交`feat: stream large voice assets to GitHub safely`。

### Task 4: 精确来源、草稿补传和显式公开的状态机

**Files:** 完善`tools/voice_release.py`，创建`scripts/prepare-voice-release.py`及`Tests/Release/test_voice_release.py`。
**Interfaces:** 实现`prepare_voice_release`、`publish_voice_release`及`verify_public_downloads`；均消费Task2快照及Task3/fake API，发布步骤只能消费已完整重核的同一资源Release；下载器不使用带认证的API客户端。

- [ ] **Step 1:** 写失败测试`test_default_and_check_only_never_read_credentials_or_contact_api`、`test_resource_draft_is_prerelease_not_latest_and_pins_commit`，断言固定标签/名称、`draft=true`、`prerelease=true`、`make_latest='false'`和完整工具来源；`test_conflicting_tag_notes_source_or_assets_are_never_overwritten`断言无DELETE/替换/多建Release。
- [ ] **Step 2:** 运行`python3 -m unittest discover -s Tests/Release -p test_voice_release.py -v`，确认具体RED。
- [ ] **Step 3:** 实现有限分页（每页100、最多100页）及最多8层annotated tag解引用；草稿未建tag可用精确`target_commitish`，已存在tag必须落同一完整commit。每次重读Release/全部六附件的名字、上传状态、长度、SHA、来源标记和正文；只补真正缺失的附件。同名starter/重复/不同摘要、已公开冲突或错误来源明确拒绝且保留状态，不删/接管。重复执行相同已公开资源只做核对，不再次上传或修改。
- [ ] **Step 4:** 实现互斥CLI模式与`--notes`正文≤64KiB；只有显式`--prepare-draft`/`--publish`读取主动提供的认证环境。`test_retry_only_uploads_missing_files_after_interrupt`、`test_starter_asset_blocks_without_deletion`、`test_publish_requires_rechecked_complete_release_and_preserves_latest`均GREEN；publish用明确PATCH公开同一pre-release，返回后必须重新读到公开状态与精确tag；已公开但网络结果未知可幂等核对。匿名下载器从精确资源tag/文件名构造官方长期地址，使用不带凭据的opener/重定向，受预期大小与摘要限制并拒绝覆盖已有目标；先写`test_public_downloads_use_anonymous_urls_and_match_snapshot`和`test_incomplete_or_bad_download_keeps_existing_files`的RED，再实现为GREEN，所有可执行下载代码此时完成。
- [ ] **Step 5:** 提交`feat: prepare recoverable independent voice prereleases`；原`Tests/Release/test_release.py`13项回归及新增资源测试均通过，原App发版实现不改。

### Task 5: 来源记录、安装说明与实际资源准备

**Files:** 创建`docs/local-voice-downloads.md`、`docs/release-notes/voice-assets-v1.0.0.md`，更新Global Constraints列明的现有说明/README/TODO；实际附件只写忽略目录。
**Interfaces:** 正文模板与安装说明由Task2/4使用；资源tag固定最终干净工具源码提交，兼容App源仍为375ff36，原引擎上游sourceCommit保持。来源字段不得宣称全部许可已核实。

- [ ] **Step 1:** 用已有一手资料补强S1v3等能确认的来源；逐项保留G2PW内部对应、ERes checkpoint与胡桃公开分发声明的实际未知项，记录日期/出处，不静默改模型或把本地localOnly历史记录重写成已有公开许可。
- [ ] **Step 2:** 编写简明中文步骤与待发布资源页：引擎只适用M系列、打开DMG后在App选择卷内真正引擎文件夹；胡桃ZIP先解压，再选三文件目录，导入/绑定/启用/试听。明确需App0.7.0；当前0.7.0仍为需登录、14天保留的CI产物，普通App公开Release需单独指令，不将旧v0.1.19写作兼容入口。
- [ ] **Step 3:** 运行Release/LocalVoice离线回归与文档链接/附件命名检查，核对`.github/workflows/macos-build.yml`自动发现新Release测试且上传范围不变；不增加下载/上传模型或默认资源发布任务。提交`docs: explain independent voice downloads and provenance`。
- [ ] **Step 4:** 在干净提交运行`tools/package-voice-assets.py`，传选定候选、原e1、资源版本1.0.0与当前完整工具commit，生成六附件；运行`scripts/prepare-voice-release.py --assets <六附件目录> --version 1.0.0 --commit <同一SHA> --notes <已准备正文> --check-only`，必须离线通过。正文/小清单渲染进忽略目录，避免把自己的commit写进待提交文件形成自引用循环。
- [ ] **Step 5:** 保存实际六附件路径、大小/SHA、来源/待核实项和正文供后续审阅；此时只记本地候选，未上传/建远端标签。Task6若修复工具源码，重新用最终干净提交生成并复核这些小清单/实际包，旧候选保留。

### Task 6: 实际兼容探针、最终回归与一次整体评审

**Files:** 创建`docs/voice-distribution-validation.md`最终本地记录，更新TODO/AGENTS；临时Swift探针与所有证据位于`.build/voice-distribution-validation/`，不登记App源码/测试target。
**Interfaces:** 消费Task1–5的最终六附件与来源；产出可供用户最终公开审核的清单/正文及全部证据。用户批准计划后本任务仍不自动公开。

- [ ] **Step 1:** 解压实际胡桃ZIP到新中文/空格目录。用现有0.7.0本地PetCore框架编译优化只读/隔离探针：调用公开`LocalVoiceLibrary(root:<临时库>).stage(folder:)`验证真实三文件/PCM/SHA，并`discard`清理本次stage；不调用internal的`LocalVoiceFile`或个人库、不发声。引擎候选只读挂载后调用公开`LocalVoiceEnginePackage.preview(folder:)`并另用`verify_engine_tree`核对全量SHA/执行位，`preview`本身不算全量摘要通过。
- [ ] **Step 2:** 运行`python3 -m unittest discover -s Tests/Release -v`及`python3 -m unittest discover -s Tests/LocalVoice -v`；离线check-only通过、所有真实包读取/核验退出0。保留实际测试计数，不把旧13/38固定当新增后总数。App源码未变，不重跑597项无变化原生测试或替换日用App。
- [ ] **Step 3:** 在实现自审、实际数据与源码干净后发起一次新的独立整体代码评审（沿用gpt-6-astra/high），覆盖375ff36至当前完整范围、五项Review Focus、所有实际候选与证据边界。评审只读、不读个人资料，不委派逐任务评审；只对经核实问题作RED→GREEN修复，不派第二次整体评审，保留Minor与代价。
- [ ] **Step 4:** 最终修复后重跑受影响离线套件和真实包/check-only；冻结干净工具来源与完整六附件/正文，核对Git新增对象没有模型/录音/runtime、工作区与原件状态明确。仅归档本计划账本，不碰旧计划；Task7尚待公开指令时保持外部步骤未完成，不把全计划标complete。
- [ ] **Step 5:** 向用户展示资源tag、六文件字节数/摘要、实际压缩结果、来源未知项、拟发布正文及只在M4验证的边界；申请具体“推送工具代码并发布这份资源预发布”的最终指令。若鉴权工具需要用户主动登录，也在具体页面/命令就绪后说明，不索要聊天中发送密钥。

### Task 7: 获明确指令后同步、发布及匿名下载验证

**Files:** 只更新既有说明的真实状态/链接及忽略目录的发布证据；不增加App普通Release，不改个人App/引擎。
**Interfaces:** 消费用户批准的同一工具commit、六附件、tag/正文与发布API；调用Task4已实现并经Task6整体评审的`verify_public_downloads`，只发送无认证下载请求，不向重定向域传token。此阶段不新增未经评审的执行代码。

- [ ] **Step 1:** 取得上述具体指令后fetch核对远端，普通快进同步用户批准范围的工具分支/main，禁止强推；检查普通CI新增离线测试与既有App流程。远端若有额外改动先核实，不隐含改源或重建包冒充已批准内容。
- [ ] **Step 2:** 以受支持认证运行显式draft模式，或使用用户现有GitHub界面在精确来源建同一资源草稿；核对全部上传后才显式公开为pre-release、非Latest。无可用认证/上传工具时交付已检文件及具体待用户步骤，不能把本地草稿正文当远端草稿。复用同一批准范围，不再索要重复发布批准。
- [ ] **Step 3:** 用不带凭据的公开入口下载六附件至新的忽略目录，流式核对大小/SHA与批准快照，ZIP内部三文件/外层说明及引擎清单证据对应；固定GitHub长期`releases/download/<tag>/<filename>`而非过期签名URL。下载失败保留可重试状态，不自动另建Release或改附件。
- [ ] **Step 4:** 读取资源Release公开状态/prerelease/tag完整来源；读取普通App`/releases/latest`，必须仍是原普通App版本（若用户另有独立App发布指令，则与那一明确结果核对）。不能只看发布HTTP 200或网页标题。
- [ ] **Step 5:** 补真实下载/发布时间、链接与摘要；明确资源发布和App公开发行不同。按同一同步授权提交说明并普通推送，产品/工具代码未变化时不重复本地全测。确认全部必需步骤实际完成后才将本计划完成、归档/删除本计划workspace；失败/待用户操作则保留准确未完成项，不用预算或收尾需要改记成功。

## 自审与执行交接

作者自行审查，不委派计划评审：设计的大小/容器限制由Task1/2覆盖，六附件/来源/ZIP由Task2/5覆盖，流式上传/来源/补传/显式状态由Task3/4覆盖，真实现有App兼容与一次评审由Task6覆盖，具体公开指令与匿名复核/Latest由Task7覆盖。五项Review Focus均有归属及可观察断言；四个打包接口、两个数据值和发布/下载接口在各任务保持同名，明确Core preview不代替全摘要、内部Swift方法不跨模块调用、原App脚本不复用大文件read_bytes、清单不自引用。

尚待用户审核本计划。沿用已选Native本会话方式，不重新询问执行模式；计划通过后连续推进本地Tasks1–6，不逐任务等待确认，Task7只等待已说明的最终具体同步/公开指令或必要登录操作。
