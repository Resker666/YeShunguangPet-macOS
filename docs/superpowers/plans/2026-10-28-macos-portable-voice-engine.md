# 本地语音独立安装 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 用户已指定本会话原地实施，不额外建工作树，不委派逐任务实现或评审；最后一次新的独立整体代码评审。

**Goal:** 为 M 系列 Mac 提供不依赖外部 Python 的独立引擎 DMG，以及 App 内有取消、修复和失败恢复的离线安装入口。

**Architecture:** 开发侧构建固定的可搬移 Python、推理依赖和公共模型，独立 DMG 仅携带引擎文件夹。PetCore 负责严格包清单、受限文件复制、版本目录、排他锁和原子描述；App 负责有界自检子进程、唯一安装状态及双窗/退出集成。安装使用独立后台工作者，不把大文件复制塞入聊天 FIFO。

**Tech Stack:** Swift 6、AppKit、Foundation/Darwin/CryptoKit、XCTest；开发侧 Python 3.12 Build Standalone、固定 GPT-SoVITS 与既有推理依赖；系统 hdiutil 仅由开发打包脚本使用。

**Spec:** `docs/superpowers/specs/2026-10-28-macos-portable-voice-engine-design.md`，用户于2026-10-28明确“认可书面设计，进入实施计划”。用户随后已明确认可本计划并要求按本会话方式实施；当前Task1完成，后续按账本继续，不代表最终产物已验证。

## Global Constraints

- 0.7.0/build30；App 仍最低 macOS14.0、双架构构建；独立引擎仅 arm64，macOS14+为兼容目标、当前仅M4可实测。禁止以 minos/交叉构建宣称旧系统或外机运行通过。
- 固定 profile `gpt-sovits-v2proplus-cpu1`、上游提交 `b4570b876f5c086819ba84e3215472733c6a7b70`、解释器 `runtime/bin/python3.12`；禁止复制原 Homebrew venv 冒充可搬移运行时。
- 包 `engine.json` schema1 + `payload/{runtime,source,engine-assets.json,licenses}`；清单16MiB、100,000文件、32层、单文件2GiB、总内容12GiB；仅普通文件/目录，无包内链接或特殊文件。
- 描述schema1保持可读；新安装写schema2。主schema13、角色v2、voice1、语音包/库schema1、个人设置/聊天/记忆/Keychain保持；不自动迁移、绑定、启用或发声。
- 预览不执行代码；确认后复制/校验/固定自检/原子切换。自检120秒、有界输出、准确自有PID停止；旧引擎保留，失败/取消不能假成功，清理仅限本次UUID。
- 真实探针只用隔离settings和已确认e1包；不读个人AI正文/正式Keychain、不请求API/麦克风、不改登录项；实验/备份/旧日用引擎不移动或删除。
- 开发侧可按固定来源取得依赖并构建；App安装时不联网、不pip、不shell、不自动清除quarantine。普通App/CI不包含或上传Python/底模/录音/引擎DMG。
- 只本地提交；本版push/tag/Release/模型上传需用户新指令。仅本计划获准后建立`.superpowers/sdd/2026-10-28-macos-portable-voice-engine/progress.md`，不恢复已完成计划。

## Review Focus

1. 搬移后宿主机碰巧有Homebrew导致假通过：Task1/3/9须审计真实依赖闭包并在新路径用独立解释器运行，包含Python stdlib及jieba扩展。
2. 用户确认后源包/路径被替换：Task2/4须拒绝manifest变化、目录身份变化、父目录链接和复制期间文件变化，旧描述保持原字节。
3. descriptor已成功rename后取消到达：Task4/6须返回已安装，绝不回写旧描述或误删当前UUID；提交前取消则旧引擎保持。
4. 保存失败后换角色/关窗，另一进程又切换引擎：Task6/7须保留已接受候选，重试停输出/重新持锁/核对旧描述，拒绝覆盖外部变更。
5. 无聊天写入但自检/清理尚未结束：Task5/7须使正常退出等待真实子PID与文件资源，停止失败可重试/取消退出/明确退出，不能补播或无限等。

## File Structure / Shared Contracts

- `tools/local_voice_runtime.py`：开发运行时构建、固定下载校验、wheel准备；`tools/local_voice_macho.py`：只读原生依赖审计；`tools/local_voice_package.py`与`tools/package-local-voice-engine.py`：资产整理/清单/DMG。固定来源记录到`tools/local-voice-runtime-m4.json`，新依赖锁独立于既有0.6准备工具。
- `Sources/PetCore/LocalVoice/LocalVoiceEngineManifest.swift`：严格包模型/路径；`LocalVoiceEnginePackage.swift`：预览及安全枚举/复制；`LocalVoiceEngineStore.swift`：版本事务/锁/备份；修改现有`LocalVoiceEngine.swift`只增schema2兼容。
- `Sources/YeShunguangPet/Chat/Voice/LocalVoiceEngineProbe.swift`与`Resources/LocalVoice/probe.py`：固定自检；`LocalVoiceEngineWorker.swift`：独立actor调用Core；`ChatLocalVoiceEngineController.swift`：MainActor安装编排和可观察状态；`ChatLocalVoiceEngineView.swift`：原生操作界面。
- `Tests/Support/LocalVoiceEngineFixtures.swift`：小包/受控工作者/探针；按职责新增Core/Mac/Python测试。每个新Swift文件登记到Xcode相应App/PetCore/无host测试target，资源目录仍由现有机制整体复制。
- 核心公开值均`Equatable, Sendable`：`LocalVoiceEngineEntry(path:String,bytes:UInt64,sha256:String,executable:Bool)`；`LocalVoiceEngineManifest`含全部下列清单字段；`LocalVoiceEnginePreview(folder:URL,manifest:LocalVoiceEngineManifest,manifestHash:String)`；`LocalVoiceEngineCandidate(versionID:UUID,preview:LocalVoiceEnginePreview,previousDescriptor:Data?,configuration:LocalVoiceEngineConfiguration)`；`LocalVoiceEngineProgress(phase:LocalVoiceEngineWorkPhase,completedBytes:UInt64,totalBytes:UInt64)`，Core的WorkPhase仅copying/verifying。candidate由store产生，不能由导入清单指定本机版本UUID；存储层可私有携带源目录身份，configuration只能由固定受控路径构造。
- App的UI状态`LocalVoiceEnginePhase`为idle/previewing/awaitingConfirmation/stopping/copying/verifying/probing/activating/installed/checking/cancelling/failed；Core的`LocalVoiceEngineSnapshot`含可读status、可选descriptor/configuration及包名/版本，worker后台构造，不在render或MainActor内resolve读盘。失败区分activationPending、cleanupPending UUID与probe资源未确认，不把它们笼统清空。

---

### Task 1: 可搬移Python与原生依赖的开发侧构建

**Files:** 新建`tools/local_voice_runtime.py`、`tools/local_voice_macho.py`、`tools/local-voice-runtime-m4.json`、`Tests/LocalVoice/test_portable_runtime.py`、`test_macho.py`；复用`tools/local-voice-requirements-m4.txt`作输入，不修改旧venv准备行为。

**Interfaces:** `prepare_runtime(build_root:Path, lock:dict, *, runner=subprocess.run) -> Path`返回自包含runtime；`audit_macho_tree(root:Path, *, minimum_os=(14,0)) -> dict`返回每个架构切片/最低系统/加载依赖/解析结果，失败抛异常。清单固定Python下载URL/完整版本/发行构建/官方SHA256及wheel/源码来源摘要；所有实际使用的106项直接/间接依赖必须有固定版本及制品哈希。

- [x] **Step 1: 写RED。** `test_download_digest_mismatch_never_executes`断言错误摘要调用runner次数0；`test_native_audit_rejects_external_load_and_newer_os`用小Mach-O字节/受控工具输出分别断言minos27、外部LC_LOAD、缺失@rpath目标失败，`test_dylib_id_is_not_a_load_dependency`断言单独LC_ID文本不构成宿主依赖。`test_symlink_materialization_rejects_outside_target`断言外链失败、内链转换为普通文件且字节相同。
- [x] **Step 2: 验RED。** `python3 -m unittest discover -s Tests/LocalVoice -p 'test_portable_runtime.py' -v`及`-p 'test_macho.py'`，确认失败来自新接口缺失/断言，而不是环境服务错误。
- [x] **Step 3: 最小实现。** 固定官方Python3.12 arm64制品，取得并校验后构建独立runtime；沿用兼容版本，在MACOSX_DEPLOYMENT_TARGET=14.0下重建jieba-fast等需要的扩展。删除无用绝对shebang入口，不创建venv外链；审计全部原生切片的实际依赖闭包、stdlib和minos，修改二进制后签名并记录最终哈希。不能仅搜索字符串或改minos数值。构建输入与输出均用新的忽略目录，不调用个人runtime。
- [x] **Step 4: 验GREEN及风险门槛。** 上述两组测试全通过；实际新runtime搬到另一中文空格目录，以系统PATH运行其`bin/python3.12`，报告`sys.executable/prefix/base_prefix`及torch/torchaudio/onnxruntime/jieba_fast等原生import。完整审计无宿主非系统依赖且全部arm64切片floor≤14.0；这不是macOS14实机结论。此门槛失败则先修复，不能继续以外部Python代替交付。
- [x] **Step 5: 本地提交。** `git add tools Tests/LocalVoice`（只明确新增的小源码/锁文件，检查无运行时文件），`git commit -m 'build: prepare a relocatable arm64 voice runtime'`。

### Task 2: 严格引擎包模型与只读预览

**Files:** 新建Core的`LocalVoiceEngineManifest.swift`、`LocalVoiceEnginePackage.swift`，`Tests/PetCoreTests/LocalVoiceEngineManifestTests.swift`、`LocalVoiceEnginePackageTests.swift`及`Tests/Support/LocalVoiceEngineFixtures.swift`；更新工程target登记。

**Interfaces:** `LocalVoiceEngineManifest.decode(_ data:Data) throws -> Self`；清单准确键为`schemaVersion,id,version,name,architecture,minimumOS,pythonVersion,profile,sourceCommit,files`，files准确键为`path,bytes,sha256,executable`。`id`复用现有皮肤ID规则、version为稳定三段数字、name≤80UTF16、Python为3.12完整数字版本；固定arm64/14.0/profile/commit。`LocalVoiceEnginePackage.preview(folder:URL) throws -> LocalVoiceEnginePreview`只读有界清单/目录类型，不执行、不复制大包。必需文件`runtime/bin/python3.12`、`engine-assets.json`及非空source/licenses子树；文件记录路径相对于payload。

- [x] **Step 1: 写RED。** `testStrictManifestAndFixedContract`断言合法小包解析、非布尔executable/重复键/未知键/源版本或架构错误失败；普通空文件（如__init__.py）允许且摘要必须为真实空字节摘要，固定解释器不得为空。`testLimitsAndNormalizedPathCollisions`断言16MiB+1、100001记录、33层、2GiB+1单项、12GiB+1总量、UInt64溢出、NFC/大小写冲突、文件与父目录冲突失败。`testPreviewDoesNotExecuteOrCreateDataRoot`断言包内可执行文件未调用、目标root不存在、候选源字节不变。
- [x] **Step 2: 验RED。** `bash scripts/test.sh -only-testing:PetCoreTests/LocalVoiceEngineManifestTests -only-testing:PetCoreTests/LocalVoiceEnginePackageTests`。
- [x] **Step 3: 实现模型/预览。** 使用StrictJSON及流式/有界读取，拒绝路径逃逸、控制字符、反斜线/空片段、根和内部链接/特殊文件；只忽略不复制`.DS_Store`。清单预览保留原字节SHA，记录源身份；本机平台检查由注入条件决定，Intel入口可测试为拒绝。不要复用只能承载16KiB角色清单的旧包类型。
- [x] **Step 4: 验GREEN。** 上述测试通过，加入包根/中间目录链接、缺少固定解释器、清单中的额外脚本入口字段、空licenses/source、重复斜线及`..`路径回归；原LocalVoiceManifest/Package测试通过。
- [x] **Step 5: 本地提交。** 仅暂存本Task的Core/Tests/工程文件，`git commit -m 'feat: validate offline local voice engine packages'`。

### Task 3: 生成公共引擎文件夹与独立DMG

**Files:** 新建`tools/local_voice_package.py`、`tools/package-local-voice-engine.py`、`Tests/LocalVoice/test_engine_package.py`；新增`docs/local-voice-engine-installation.md`的开发构建部分。

**Interfaces:** `assemble_engine(runtime:Path, experiment:Path, output:Path, *, engine_id:str, version:str) -> dict`消费Task1 runtime及固定资产源；`write_engine_manifest(package:Path, metadata:dict) -> dict`产生Task2格式；`package_engine_dmg(package:Path, output:Path, *, runner=subprocess.run) -> Path`只执行参数数组的系统hdiutil并生成sha256。CLI明确`--runtime --experiment --output --version`，不猜个人路径、覆盖已存在包或读取个人LocalVoice。

- [x] **Step 1: 写RED。** `test_assembly_excludes_voice_training_and_host_paths`用小资产断言无s2/reference/录音/venv/experimentPath/个人路径；`test_manifest_is_deterministic_and_hashes_final_bytes`断言排序、字节数、最终签名后哈希一致；`test_dmg_uses_argument_array_and_keeps_source`断言带空格中文路径完整作为一个参数、打包失败不删除源包。
- [x] **Step 2: 验RED。** `python3 -m unittest discover -s Tests/LocalVoice -p 'test_engine_package.py' -v`。
- [x] **Step 3: 实现并组装。** 复用既有固定源码/公共资源摘要，在新输出中生成纯运行资产清单；保持上游文件字节，收集Python/依赖/源码/底模许可与来源库存，不引入训练权重。最终包manifest覆盖全部payload文件及执行位；Task1审计通过后再封装DMG和安装说明，模型/DMG不进Git。运行时及包内链接全部转换或拒绝。
- [x] **Step 4: 验GREEN与跨语言合同。** Python测试通过；用真实输出的`engine.json`交给Task2 Swift解析器离线读取并核对必需路径/总量/摘要。真实DMG只读挂载，核对包与外部文件夹库存一致后弹出；记录实际下载/安装/压缩/峰值空间，不预先声称包大小或外机通过。
- [x] **Step 5: 本地提交。** 仅小工具/测试/说明，`git commit -m 'build: package an independent offline voice engine image'`。

### Task 4: 版本目录、排他锁和原子切换

**Files:** 新建`Sources/PetCore/LocalVoice/LocalVoiceEngineStore.swift`、`Tests/PetCoreTests/LocalVoiceEngineStoreTests.swift`；修改`LocalVoiceEngine.swift`、Task2包文件与夹具、工程登记。

**Interfaces:** `LocalVoiceEngineStore.init(dataRoot:URL, hooks:Hooks = .live)`；`acquire() throws -> LocalVoiceEngineLease`持有use.lock非阻塞EX锁；`begin(_ preview:LocalVoiceEnginePreview, lease:LocalVoiceEngineLease) throws -> LocalVoiceEngineCandidate`产生私有最终UUID和旧描述快照；`copy(_ candidate:LocalVoiceEngineCandidate, progress:@Sendable(LocalVoiceEngineProgress)->Void, checkCancelled:@Sendable()->Bool) throws`；`activate(_ candidate:LocalVoiceEngineCandidate, lease:LocalVoiceEngineLease, checkCancelled:@Sendable()->Bool) throws -> LocalVoiceEngineDescriptor`；`discard(versionID:UUID, lease:LocalVoiceEngineLease) throws`拒绝当前UUID。Hooks仅注入空间/读取期间观察/原子写/删除等真实失败边界，不提供绕过验证的产品开关。

- [x] **Step 1: 写RED。** `testInstallCopiesAndVerifiesWithoutChangingCurrentBeforeActivation`断言复制后旧描述原字节、目标权限/摘要正确；`testSourceMutationOrLinkedParentCannotEscape`在读取钩子替换源目录/中间父目录/增长文件并断言失败；`testCommitCancellationHasOneLinearizationPoint`断言rename前取消保旧、rename后取消结果为成功且不删当前；`testRetryRejectsChangedDescriptorAndKeepsOldVersion`断言旧身份变化拒绝覆盖。另测空间不足、部分复制/备份/写失败及清理失败保留明确UUID。
- [x] **Step 2: 验RED。** `bash scripts/test.sh -only-testing:PetCoreTests/LocalVoiceEngineStoreTests -only-testing:PetCoreTests/LocalVoiceEngineTests`。
- [x] **Step 3: 实现事务。** 分组件`openat/O_NOFOLLOW`枚举并复制，检查源FD前后stat、目录身份、总预算及取消，每64KiB流式摘要；0700目录、0600普通文件/0700执行文件。空间至少总内容+max(256MiB,总量10%)，实际ENOSPC仍处理。完整重验后才允许activate；首次切换前备份有界普通旧描述（缺失则无需），备份失败不切换。schema2在原schema1字段之外增加`packageID,packageVersion,packageName,manifestSHA256`、python固定新路径，版本目录保留`engine.json`用于检查；current上限16KiB。坏/未知旧描述不被启动重写，明确修复时只备份≤16KiB普通原字节，链接/超限拒绝覆盖。锁对象作用域释放，所有失败返回可定位本次候选及清理状态。
- [x] **Step 4: 验GREEN。** 上述测试及原schema1测试通过，`testSchema2RejectsLinkedRuntimeAndKeepsLegacyReadable`断言schema2解释器/中间目录链接与清单身份不符失败、legacy原合法venv仍可读；实际小包复制后全量字节重验、取消测试保旧；持SH锁的独立子进程令EX失败且不建立版本目录，释放后可重试；外部描述修改、当前候选误删、目标父目录链接均拒绝。
- [x] **Step 5: 本地提交。** `git commit -m 'feat: install voice engines with versioned atomic activation'`，只暂存本Task文件。

### Task 5: 固定离线自检与有界子进程

**Files:** 新建`Resources/LocalVoice/probe.py`、`Sources/YeShunguangPet/Chat/Voice/LocalVoiceEngineProbe.swift`、`Tests/LocalVoice/test_engine_probe.py`、`Tests/PetMacTests/LocalVoiceEngineProbeTests.swift`；更新fixture/工程。

**Interfaces:** `LocalVoiceEngineProbeReport`含pythonVersion/profile/sourceCommit；`@MainActor protocol LocalVoiceEngineProbing: AnyObject, Sendable { var hasResources:Bool { get }; func run(configuration:LocalVoiceEngineConfiguration, requestID:UUID) async throws -> LocalVoiceEngineProbeReport; func stop() async -> Bool }`。真实`LocalVoiceEngineProbe.init(scriptURL:URL,limits:Limits = .init())`仅调用固定Python和固定App脚本。脚本CLI为`--engine-root --cache-root --request-id`，stdout只输出单条`v=1,event=checked,requestID,pythonVersion,profile,sourceCommit`成功JSON，非零/未知字段/错ID失败。

- [x] **Step 1: 写RED。** `testProbeValidatesOfflineWithoutVoiceOrDownloads`用替身模块断言不加载S2/声卡、不联网/不调用pip、不写source；`testProbeRejectsWrongReplyAndOversizedOutput`断言64KiB行/stdout256KiB/stderr1MiB边界；`testCancelAndTimeoutConfirmOwnedPIDExit`用真实小助手覆盖无输出挂起、忽略TERM及停止失败；`testParentPipeEOFEndsBlockedProbe`断言关闭父输入管道后准确子PID退出、其他哨兵进程不动。`testMainActorRemainsResponsiveWhileProbeImports`以握手阻挡助手并断言主线程回调继续。
- [x] **Step 2: 验RED。** `python3 -m unittest discover -s Tests/LocalVoice -p 'test_engine_probe.py' -v`；`bash scripts/test.sh -only-testing:PetMacTests/LocalVoiceEngineProbeTests`。
- [x] **Step 3: 实现。** 脚本先检查版本/架构/固定公共资产，复用现有离线guard/cache路径与主要推理import，不构造TTS模型、不改上游配置。父进程已持EX锁，probe不再请求SH锁；启动环境仅系统PATH及固定离线变量，无用户PYTHONPATH。launch/管道读写在后台、读端非阻塞，stdout/stderr持续排空而不记录私人信息；120秒超时，TERM2秒再KILL2秒，结果仅在准确PID退出及句柄清理确认后完成。probe监听父输入管道EOF以退出阻塞初始化，不在stdin接收任意命令。可复用原LocalVoiceProcess的明确停止机制，避免无必要的全局进程框架重构。
- [x] **Step 4: 验GREEN。** 两组测试及原LocalVoiceProcessTests通过；在新独立runtime+公共payload真实运行固定probe，离线import成功且源字节不变。缺少资产/错误Python/缺库给明确分类，不用捕获所有错误后报成功。
- [x] **Step 5: 本地提交。** `git commit -m 'feat: check voice engines with a cancellable offline probe'`。

### Task 6: 唯一安装工作者与可恢复控制器

**Files:** 新建`LocalVoiceEngineWorker.swift`、`ChatLocalVoiceEngineController.swift`、`Tests/PetMacTests/LocalVoiceEngineWorkerTests.swift`、`ChatLocalVoiceEngineControllerTests.swift`；扩展独立fixture/工程。

**Interfaces:** `protocol LocalVoiceEngineWorking:Sendable`提供async throws的`preview(folder:URL)->Preview`、`begin(_ preview:Preview)->Candidate`、`copy(_ candidate:Candidate,progress:@Sendable(Progress)->Void)`、`activate(_ candidate:Candidate)->Descriptor`、`discard(_ candidate:Candidate)`，以及async的`releaseLease()`、`current()->Snapshot`；名称中的Preview/Candidate/Progress/Descriptor/Snapshot均为上面完整类型别名。`actor LocalVoiceEngineWorker`持有store/唯一lease，大文件方法执行在该actor。`@MainActor ChatLocalVoiceEngineController.init(worker:any LocalVoiceEngineWorking,probe:any LocalVoiceEngineProbing,canStart:@escaping()->Bool,stopOutput:@escaping() async->Bool,onActivated:@escaping()->Void)`；提供`preview(folder:)`、`confirmInstall()`、`checkCurrent()`、`cancelPreview()`、`cancelInstallation()`、`retryPending()`、`beginTermination()`、`cancelTermination()`、`waitForPending() async`、`retryForTermination() async`、`dispose()`，可观察phase/preview/progress/error/snapshot与`isBusy/blocksServices/hasPendingResources/hasUnsaved/terminationError`。

- [x] **Step 1: 写RED。** `testOnlyOneConfirmedInstallAndProbeCanActivate`断言确认前不执行/复制、停止失败不开始、重复确认只一次；`testFailedActivationRetainsCandidateAcrossRoleAndWindowChanges`断言同一UUID重试不重新复制/自检/发声；`testPendingRetryReleasesAndReacquiresLease`断言旧引擎可用且外部描述变化拒绝覆盖；`testCancelBeforeAndAfterActivationDoesNotDeleteCurrent`断言迟到取消不回滚。`testCancelledCopyCleansOnlyItsOwnCandidate`断言清理失败保token与重试入口，子进程未退出时不删其文件。
- [x] **Step 2: 验RED。** `bash scripts/test.sh -only-testing:PetMacTests/LocalVoiceEngineWorkerTests -only-testing:PetMacTests/ChatLocalVoiceEngineControllerTests`。
- [x] **Step 3: 实现编排。** 明确prepare/copy/probe/activate边界，同一task合作取消；worker持EX覆盖复制/自检/提交，释放后的重试重新验证候选及旧描述。进度在后台节流约100ms再转MainActor，不为每chunk排一个UI任务。确认后的工作不因关窗/角色变化丢失；睡眠/退出显式取消可取消阶段，正在原子提交的短事务完成。等待用户处理activationPending时释放锁且blocksServices=false，旧引擎可用；未确认probe退出/活动copy/清理时保留资源状态。检查当前引擎用同一单飞/停止/锁/探针，缺失只报告，不创建环境。
- [x] **Step 4: 验GREEN。** 两组测试通过，加入取消退出不续装、检查不切换/启用、可用旧schema1和新schema2检查、旧任务晚结果忽略、清理重试不删当前，以及主线程在受控复制期间继续响应。对Task4失败通过受控存储钩子注入，不靠chmod猜测磁盘错误。
- [x] **Step 5: 本地提交。** `git commit -m 'feat: coordinate recoverable local voice engine installation'`。

### Task 7: 聊天、双窗和正常退出集成

**Files:** 修改`ChatController.swift`、`ChatLocalVoiceController.swift`、`AppDelegate.swift`、`StatusBarController.swift`；新建`Tests/PetMacTests/LocalVoiceEngineIntegrationTests.swift`，复用Chat/Voice/LocalVoiceProduction夹具。

**Interfaces:** ChatController新增只读`localEngine:ChatLocalVoiceEngineController?`及`configureLocalVoiceEngine(worker:any LocalVoiceEngineWorking,probe:any LocalVoiceEngineProbing)`，只能配置一次；production在configureVoice之后、创建双窗之前调用。复用voice.stopAndWait作安装停止屏障；安装onActivated刷新语音库engine状态。既有`hasPendingTerminationResources/terminationResourceError/canRetryTerminationSave/terminationSaveError/waitForTerminationResources/retryTerminationResources/retryAllPendingSaves`同时覆盖installer，保留原FIFO/语音等待语义。

- [x] **Step 1: 写RED。** `testTextSendAndArchiveFIFORemainUsableDuringInstallation`断言阻挡复制时文字往返/保存完成、无自动朗读/录音；`testEngineMutationBlocksNewVoiceAndRolePackageMutation`断言旧输出先停止、并发入口被拒、结束后恢复；`testExitWaitsForProbeWithEmptyChatQueue`断言队列空仍terminateLater等待，停止失败三种决定可达。`testFullQuickHandoffAndRoleChangeKeepOneAcceptedInstall`断言安装实例/候选不变、未确认预览真关闭才取消。
- [x] **Step 2: 验RED。** `bash scripts/test.sh -only-testing:PetMacTests/LocalVoiceEngineIntegrationTests`。
- [x] **Step 3: 集成。** `canPrepareVoiceInput`及voice.canUseServices加入安装blocksServices；localVoices.canMutate加入同一门控，不能把它加进文字canSend的共同canMutate。复用现有objectWillChange异步MainActor转发，不引入通知回调同步跨线程等待。setSleeping/beginTermination/dispose明确通知installer，正常退出既等待FIFO也等待安装/自检，资源错误不被保存成功掩盖；状态检查不读取个人AI。日用启动不自动安装/检查/迁移引擎。
- [x] **Step 4: 验GREEN。** 新测试、ChatVoiceIntegrationTests/LocalVoiceProductionIntegrationTests通过；受控安装保存失败退出重试后只启用一次，取消退出后不恢复旧声音/安装；旧voice输出停止失败规则不倒退，两个窗口共享同一实例。onActivated不能抢占正在退出或语音库原事务。
- [x] **Step 5: 本地提交。** `git commit -m 'feat: integrate engine installation with voice and app lifecycle'`。

### Task 8: 原生安装界面、版本和普通包库存

**Files:** 新建`ChatLocalVoiceEngineView.swift`、`Tests/PetMacTests/LocalVoiceEngineWindowTests.swift`；修改`ChatLocalVoiceSettingsView.swift`、`ChatVoiceSettingsView.swift`、`ChatWindowController.swift`、`Sources/YeShunguangPet/Info.plist`、`scripts/verify-app.py`、`Tests/Distribution/test_local_voice.py`、README/TODO/安装说明；更新工程登记。

**Interfaces:** `ChatLocalVoiceEngineView.init(controller:ChatController,hasBlockingModal:@escaping()->Bool)`及`render()`、`cancelPanel()`；嵌入现有语音页引擎区域，不另建设置窗。NSOpenPanel只选择单文件夹，按钮“安装或修复本地引擎…”/“检查当前引擎”；预览显示来源信任提示、包名/版本/体积/确认/取消，活动显示阶段和实际字节进度，失败显示相应重试/取消/清理。真离页/关窗取消panel/未确认预览；已确认工作与full/quick交接分开处理。

- [x] **Step 1: 写RED。** `testPreviewRequiresConfirmationAndDoesNotBindOrEnableVoice`断言选包后不开始、不发声、不改index/voice；`testCompactScrollableViewExposesCancelAndRetry`在440×420浅/深色断言所有操作可滚动到且busy状态准确；`testIntelAndUnconfiguredStatesRemainUsable`断言Intel安装禁用/系统语音保留、无引擎冷启动只读。库存测试先期望新增probe.py并拒绝真正runtime/models混入普通App。
- [x] **Step 2: 验RED。** `bash scripts/test.sh -only-testing:PetMacTests/LocalVoiceEngineWindowTests`及受影响小型库存测试，记录因新行为未实现而失败。
- [x] **Step 3: 实现界面与元数据。** 纯render消费缓存状态，不读文件/hash/枚举音色；文件面板/确认纳入现有阻挡规则。引擎取消按钮不复用聊天停止按钮；检查/修复与音色绑定明确分开。Info.plist升0.7.0/build30，同步verify-app.py::verify的expected_adapter及test_local_voice.py::EXPECTED为实际6文件（含probe）；Xcode资源目录已有folder引用，不逐文件登记probe。保留普通包排除模型/venv/bytecode并补runtime明显误入的校验，不给App构建脚本增加调用tools的强制钩子（现分发夹具不复制tools）。不扩充prepare-release.py::collect_assets的八附件协议或CI大模型产物。使用说明包含打开DMG/选取文件夹/角色另导入/修复/旧描述恢复/系统拦截实际边界。
- [x] **Step 4: 验GREEN及视图。** 新窗口测试与原LocalVoiceWindow/ChatVoiceWindow测试通过；主执行者查看隔离浅深色最小窗截图，记录缓存/程序化输入不能代替真实鼠标或Gatekeeper。全部Python离线测试及Release离线测试通过，普通包资源字节与库存一致。
- [x] **Step 5: 本地提交。** `git commit -m 'feat: add native offline engine installation controls'`，检查只提交源码/资源适配器/小文档。

### Task 9: 完整回归、一次最终评审和真实本地交付

**Files:** 新建`docs/portable-voice-engine-validation.md`；更新README/TODO/AGENTS与`docs/local-voice-engine-installation.md`；实际日志放忽略目录`.build/portable-voice-engine-validation/`，不提交包或私人数据。

**Interfaces:** 使用前面公开接口和既有构建/打包脚本，不新增产品调试后门。新计划ledger仅在计划批准后建立，完成后只归档本计划证据。

- [x] **Step 1: 完整回归。** `bash scripts/test.sh`、`python3 -m unittest discover -s Tests/LocalVoice -v`、`python3 -m unittest discover -s Tests/Release -v`全部真实通过；记录测试数量/命令/失败历史，相关新改动后重跑必要范围，不反复无变化测试。
- [x] **Step 2: 真实隔离引擎验证。** 挂载独立DMG并通过同一安装服务在隔离中文空格settings路径安装，复制/自检/保存/取消/修复与错误恢复留证；弹出DMG，将本轮新构建输入移开（不动原实验/备份/旧日用），用新runtime无外部Python路径运行固定probe与新的中文生成/原生播放启动/停止。核对源/候选/安装副本哈希、Pythonprefix、原生依赖闭包、冷ready/生成/峰值RSS/停止耗时及准确PID退出。保留既有600UTF16、180秒空闲/一次回退规则；既有测试已覆盖且未变的不为凑证据重复长等待。
- [x] **Step 3: 一次新的最终整体代码评审。** 按requesting-code-review技能审阅基线1d8f4f8至本版完整实现，保留本会话单席位/一次整体方式；有阻断项以真实RED→GREEN修复，重跑必要回归，不自动派第二评审。报告Critical/Important/Minor及有意取舍，旧0.5两项Minor仍单列。
- [x] **Step 4: 干净来源与双架构分发。** 先本地提交实现/修复，再`bash scripts/build-app.sh arm64`、`bash scripts/build-app.sh x86_64`、各自`bash scripts/package-app.sh <arch>`；`python3 -m unittest discover -s Tests/Distribution -v`通过。仅把本次8份App/校验文件放入单独的忽略子目录，再运行`python3 scripts/prepare-release.py --assets <该目录> --version 0.7.0 --commit <完整干净来源SHA> --check-only`，必须成功，不能把引擎DMG或dist历史附件一起传入。实查版本/14.0/签名/六适配器/原皮肤/来源/无运行时模型，ARM中文空格路径搬移及弹出DMG后重开；独立引擎DMG单独核对摘要/许可/库存，不上传。
- [x] **Step 5: 本地安装与记录。** 正常退出准确旧App后盲备份旧App/主配置/AI及current原字节，安装新App并核对旧设置/AI摘要/当前引擎描述未被自动改变。让用户在新UI主动安装引擎/试听，自动验证不读取私人内容或正式Keychain、不替用户绑定启用。写真实已测与待验：M4本机与可闻用户反馈分开；macOS14/其他M系列/外机Gatekeeper/Intel引擎保持未测或不支持。以`docs: record portable voice engine validation and local delivery`本地提交收尾，归档本计划ledger，不push/tag/Release。

## Plan Self-Review / 覆盖检查

作者自审，不委派计划评审。设计§1–3由Tasks1–3覆盖独立运行时/包/许可及M系列边界；§4由Task4/5/6覆盖安全文件、两代描述、固定探针与保存/取消；§5由Tasks6–8覆盖共享状态、文字不阻塞、双窗/睡眠/退出及界面；§6由Task9覆盖真实搬移、评审、干净包与如实交付。五项Review Focus均已分配明确断言。类型自查已补Core工作阶段与App UI阶段分离、候选/快照携带后台解析configuration、空普通文件合法及schema2链接检查；步骤自查保留可观察断言/真实命令，未写具体程序体。篇幅约为设计两倍，对应9项有独立验证结果的交付单元。额外只读调查仅核对CI/库存文件与现有夹具，不是第二次设计/计划评审；已据事实固定两处六文件清单及独立八附件离线目录。未把Python、模型、私人数据或整包写入CI夹具。

设计及实施计划均已获准，当前已进入实施。沿用既定Native本会话方式，不重新要求选择执行模式；计划确认后连续完成Tasks1–9、一次最终整体评审和本地交付，不逐任务等待确认。
