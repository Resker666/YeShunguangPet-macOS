# macOS Local Character Voice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在当前 Mac mini M4 上交付 0.6.0/build29：导入并绑定胡桃语音包，由 App 按需启动独立引擎朗读，可靠停止并按明确规则回退系统音色。

**Architecture:** PetCore 保存严格包/索引/引擎描述和受限文件操作；Mac 层将独立进程、原生播放器与系统朗读组合成一个共享输出路由器。语音库写入并入既有聊天 FIFO，模型与 Python 环境留在 settingsURL 同级 LocalVoice，App 只携带小体积适配器。先验证可重建的本机环境，再接入控制器、双窗和正常退出。

**Tech Stack:** Swift 6、AppKit、Foundation、AVFoundation、CryptoKit、Darwin/libproc、XCTest；Python 3.12、stdlib unittest、固定版本 GPT-SoVITS/PyTorch/中文前端，作为可选独立运行环境；现有 xcodebuild/ad-hoc/DMG/ZIP 流程。

**Spec:** [已批准的具体设计](../specs/2026-10-27-macos-local-character-voice-design.md)。用户于2026-10-27明确认可书面设计并要求进入实施计划。设计代码基线 cbe6ae4，书面设计提交13cc4f5；本计划尚待审核。

## Global Constraints

- 原地使用独立 Mac 仓库 `/Users/resker/develop/github/YeShunguangPet-macOS` 与 `codex/macos-local-character-voice`；本会话主执行者连续实施，一次最终独立整体代码评审，不额外 worktree、不委派逐任务实现/评审。
- 0.6.0/build29，Swift 6/macOS14+，arm64日用与实验 x86_64 App；本版独立引擎只准备并验证当前 M4，陌生 Mac 免 Python、Intel 引擎另做。
- 主schema13、角色v2、AI/voice.json schema1、所有旧字段和Keychain标识保持；原皮肤字节不变，Windows与Minimal Sleep只读。
- App无新增第三方链接依赖；Python/ML仅在显式准备工具中安装。App不运行pip、不自动下载、不监听端口、不接云端语音；运行时离线，DeepSeek仍只走原文字链路。
- `LocalVoice/Engine/Versions/<uuid>/`、`Voices/<uuid>/`、`index.json`与`Cache/`均相对实际settingsURL父目录；缺失数据不在普通启动时创建。临时生成任务目录0700，音频不保存为历史。
- 语音包只接收文件夹：voice.json≤16KiB、s2.pth≤256MiB、reference.wav≤1MiB；32kHz/单声道/16位PCM、3–10秒；仅可忽略且不复制.DS_Store。未知文件/子目录、重复JSON键、越界及包内链接拒绝；规范化系统外层路径别名。
- 包名≤80、参考文本≤400 UTF-16；语言zh-CN，profile固定`gpt-sovits-v2proplus-cpu1`，包/角色ID沿用皮肤ID规则；索引schema1≤64KiB，最多16包/16角色绑定。
- e1为首次接入候选，e2与所有原件/备份保留。上游源码固定b4570b876f5c086819ba84e3215472733c6a7b70且字节不改；依赖版本以已验证现场版本为起点，不把现场freeze宣称为已验证可重建锁。
- 默认不绑定、不启用、不加载模型、不发声；导入只复制登记，绑定明确先存后生效。系统语音设置与角色绑定分别应用，不伪装多文件原子事务。
- 自动朗读沿用首次成功保存的完整普通回复、最多600 UTF-16；本地单次≤600，手动>600且≤8000时明确系统读全文。原语速0.35–0.65，本地speed_factor=rate/0.5（0.7–1.3）。
- 一台worker/一个角色模型/一个请求，CPU、float32、4线程、中文、batch1、非流式；180秒无任务退出。ready≤45秒，生成≤120秒，启动/生成期间观察RSS>8GiB就停止；观察阈值不是OS硬上限。
- stdio UTF-8 JSON行≤64KiB，固定版本/会话/请求ID；聊天文字不进入argv、env、日志。WAV≤32MiB/240秒、固定父进程指定路径，验证后以不可变快照播放。
- 停止撤销播放与计算，2秒后仅强杀自己拥有的准确子进程，再最多等2秒；未确认停止不录音/朗读/回退。父管道失联自行退出，正常退出异步等资源。
- 播放前本地失败且意图有效/停止成功才至多回退一次；播放后失败、取消、换角色、安静、离页、睡眠、退出不重读、不回退、不补播。
- 自动测试使用隔离路径/假服务/小型合成数据，不访问个人AI正文/Keychain/真实API/麦克风。明确的M4验证允许加载已确认模型与生成本地新句子；可闻与物理操作分开记录。
- 只本地提交和交付；本版push/tag/Release没有授权，模型/音频/venv不进Git、普通安装包或CI附件。

## Review Focus

1. 文件面板预览后源目录被替换/删除：确认只消费已验证的私有快照，不重新信任原路径；取消不登记。归Task2。
2. 已接受模型登记/绑定排在聊天写入后，随后关窗/退出或落盘失败：FIFO顺序、旧绑定与待清理资源都不能丢。归Task2、7、8。
3. 模型初始化时stdout洪泛、半行、无ready或停止不响应：UI持续可调度，只结束准确worker，录音保持关闭。归Task4、5。
4. 没有Apple中文音色仍可使用本地模型；失败回退与同ID换肤/同步隐藏回调竞争时只保留有效意图，不重复播放。归Task6。
5. 退出发生在进程启动/生成/播放而磁盘FIFO为空时：仍等待资源，停止失败可重试/取消，取消退出不复活声音。归Task8。

---

## 文件与接口地图

| 路径 | 职责 |
| --- | --- |
| `Sources/PetCore/LocalVoice/LocalVoiceManifest.swift`、`LocalVoicePCM.swift`、`LocalVoiceIndex.swift` | 严格格式、PCM验证、不可变索引及绑定约束 |
| 同目录`LocalVoicePackage.swift`、`LocalVoiceLibrary.swift`、`LocalVoiceIndexStore.swift` | 流式摘要/私有预览、安装/删除/回滚、受保护索引 |
| 同目录`LocalVoiceEngine.swift` | 固定profile描述、路径与公共资源清单模型 |
| `Resources/LocalVoice/{voice_assets,worker_protocol,gpt_sovits_backend,worker}.py`、`engine-assets.json` | App与开发工具共用的小型适配器、受限协议及固定资源摘要；模型不放这里 |
| `tools/prepare-local-voice.py`、`tools/local-voice-requirements-m4.txt` | 明确准备新版本venv/公共资源、导出胡桃文件夹包，不随App执行 |
| `Sources/YeShunguangPet/Chat/Voice/LocalVoice/{LocalVoiceProcess,LocalVoiceOutput,LocalVoicePlayer}.swift` | 异步子进程/监控、单次本地输出、原生播放 |
| `Chat/Voice/{VoiceOutputRouting,VoiceOutputRouter}.swift` | 系统/本地路由、阶段/实际来源与一次回退 |
| `Chat/Voice/LocalVoice/{ChatLocalVoiceController,ChatLocalVoiceSettingsView}.swift` | 唯一语音库状态、预览确认/绑定/删除/重试、原生页内控件 |
| 既有`ChatPersistence.swift`、`ChatController.swift`、`ChatVoiceController.swift`、`VoiceServices.swift` | 同一FIFO、角色/代次与服务组合；不重构无关聊天逻辑 |
| `AppDelegate.swift`、`StatusBarController.swift`、`ChatVoiceControls.swift`、`ChatVoiceSettingsView.swift` | 生产装配、退出等待、双窗状态及操作入口 |
| `Tests/LocalVoice/`、`Tests/Support/LocalVoiceFixtures.swift`、Core/Mac新用例 | stdlib协议/准备工具与临时目录/假进程/原生组合回归 |
| Xcode工程、CI、verify-app/分发检查、README/TODO/验证文档 | 显式源码/资源登记、离线CI、适配器库存和真实交付记录 |

Swift文件显式加入PetCore/App及无host PetMacTests对应源码phase；4份Python和engine-assets.json通过同一源资源加入App与需要的测试resource phase，禁止维护两套拷贝。Python测试禁写pycache，打包核对资源清单，不把测试替身/安装依赖/权重夹进App。

### Task 1: 严格语音包、PCM和索引合同

**Files:** 新增Core的LocalVoiceManifest/PCM/Index；新增`Tests/PetCoreTests/{LocalVoiceManifestTests,LocalVoicePCMTests,LocalVoiceIndexTests}.swift`与`Tests/Support/LocalVoiceFixtures.swift`，登记Xcode。

**Interfaces:** `LocalVoiceManifest.decode(_ data:Data) throws -> LocalVoiceManifest`，固定字段schemaVersion/id/name/language/engineProfile/model/reference/promptText/suggestedCharacterID；资产字段file/bytes/sha256。`LocalVoicePCM.validate(_ data:Data, maximumBytes:Int, minimumSeconds:Double, maximumSeconds:Double) throws -> LocalVoicePCMInfo`返回sampleRate/channels/frames；参考传3/10秒，生成传0/240秒且始终拒绝零帧。`LocalVoiceIndex`含schemaVersion、packages:[LocalVoiceRegistration]、bindings:[String:UUID]；`binding(for characterID:String)->UUID?`、`binding(characterID:String,to id:UUID?) throws -> LocalVoiceIndex`产生新值，引用不存在包/超过数量拒绝。

- [ ] **Step 1: 写失败断言。** `testManifestRejectsDuplicateKeysAndBoolAsByteCount`、`testFixedFilesAndIDRules`、`testReferenceAcceptsThreeAndTenSecondsOnly`、`testBindingsShareManifestIDAndRejectSeventeenthRole`；断言600/8000不混为格式上限，包字段大小分别16KiB/256MiB/1MiB，索引16/17边界。Fixtures只生成小PCM和假权重；大边界使用声明/可控流或稀疏文件。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetCoreTests/LocalVoiceManifestTests -only-testing:PetCoreTests/LocalVoicePCMTests -only-testing:PetCoreTests/LocalVoiceIndexTests`；新类型缺失或指定断言失败，工程错误不算正确RED。
- [ ] **Step 3: 实现上述类型。** 复用StrictJSON先检查键/深度/长度再解码；整数排除CFBoolean、浮点伪整数和溢出。ID规则与ManifestDecoder保持准确一致，可提取共用内部校验并跑旧皮肤回归。PCM有界解析RIFF块/奇数字节填充，验证fmt/data完整边界、32k/mono/PCM16及3–10秒参考条件；生成音频使用独立最大32MiB/240秒条件。
- [ ] **Step 4: 验证GREEN。** 同一命令及`PetCoreTests/ManifestDecoderTests`；增加BOM/未知字段/错SHA长度/非法控制字符/截断PCM/超界RIFF块/重复包ID或UUID、绑定未知UUID、16/17包及600字符不截断字素的定向断言。
- [ ] **Step 5: 本地提交。** `feat: define bounded local voice packages and role bindings`。

### Task 2: 私有快照、语音库与同一FIFO存储

**Files:** 新增Core的LocalVoicePackage/Library/IndexStore、对应Core测试；修改`ChatPersistence.swift`、`Tests/Support/ChatFixtures.swift`，新增`Tests/PetMacTests/LocalVoicePersistenceTests.swift`。

**Interfaces:** `LocalVoiceLibrary(root:URL)`产生`stage(folder:URL) throws -> StagedLocalVoice`（stageID/manifest/contentID/privateDirectory）、`discard(_ staged:StagedLocalVoice) throws`、`entries(index:LocalVoiceIndex) -> [LocalVoiceLibraryEntry]`、`resolve(libraryID:UUID,index:LocalVoiceIndex) throws -> ResolvedLocalVoice`（libraryUUID/manifest/directory）。`LocalVoiceIndexStore.load()->ChatLoadResult<LocalVoiceIndex>`、`apply(_ mutation:LocalVoiceMutation) throws -> LocalVoiceCommit`；Mutation为install(StagedLocalVoice)、bind(characterID:String,libraryID:UUID?)、remove(UUID)、reset、retryCleanup([LocalVoiceCleanup])。Cleanup仅含staging/unregisteredVoice类别与UUID，不接收任意路径；Commit返回index、installedID?、cleanupPending:[LocalVoiceCleanup]。失败`LocalVoiceMutationError`提供可读类别/cleanupPending，原stage在确认保存前保留供重试。`ChatPersisting`新增`loadLocalVoiceIndex() async -> ChatLoadResult<LocalVoiceIndex>`、`stageLocalVoice(folder:URL) async throws -> StagedLocalVoice`、`discardLocalVoiceStage(_ staged:StagedLocalVoice) async throws`、`localVoiceEntries() async -> [LocalVoiceLibraryEntry]`、`resolveLocalVoice(libraryID:UUID) async throws -> ResolvedLocalVoice`；写入只走`ChatWriteOperation.localVoice(LocalVoiceMutation)`与`ChatStoredValue.localVoice(LocalVoiceCommit)`，由ChatArchiveWorker持有同一store和已提交index，解析不能接受调用方伪造的旧index。

- [ ] **Step 1: 写失败断言。** `testConfirmedImportUsesSnapshotAfterOriginalFolderReplacement`：stage后替换/删源，确认仍得到原SHA；`testCancelledPreviewNeverRegisters`、`testFIFOImportBindAndAcceptedChatWriteSurviveClosure`、`testIndexSaveFailurePreservesOldBindingAndRetryReusesStagedData`。ControlledChatPersistence继续支持holdNextWrite/failNext/waitForOperations，增加localVoice操作名，不能读个人目录。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetCoreTests/LocalVoiceLibraryTests -only-testing:PetCoreTests/LocalVoiceIndexStoreTests -only-testing:PetMacTests/LocalVoicePersistenceTests`。
- [ ] **Step 3: 实现快照与事务。** 后台有界流式复制/摘要，目录句柄与普通文件/O_NOFOLLOW约束防止链接和读取中增长；模型不整份变成UI持有的Data。stage在0700私有目录，contentID来自三份文件有序摘要。确认复制已验证stage到正式新UUID副本，不再读源；相同内容复用。install先完整文件就位再原子索引，保存成功才清stage；失败保留旧index、stage及准确cleanup信息。remove先校验所有绑定并保存新index，再清未绑定副本；清理失败通过Commit上报，索引成功不被误写为整次回滚。retryCleanup必须重新确认UUID没有登记/绑定，再按固定根清理，不能让旧清理请求删掉已重新启用的包。reset先备份index、不删模型。保留未知/坏index原字节，缺失load不创建目录。
- [ ] **Step 4: 验证GREEN。** 上述命令及`PetMacTests/ChatPersistenceTests`、`VoicePreferencesControllerTests/testVoiceFIFOIsSharedWithAcceptedChatWrites`。覆盖坏包单项隔离、源增长、根/文件链接、系统临时路径别名、.DS_Store、取消、写/清理失败、引用其他角色、16包和64KiB边界；断言voice.json/角色档案字节不变，失败重试零音频/API调用。
- [ ] **Step 5: 本地提交。** `feat: persist imported local voices through the chat write queue`。

### Task 3: 当前M4稳定环境准备与胡桃包导出

**Files:** 新增`tools/prepare-local-voice.py`、`tools/local-voice-requirements-m4.txt`、`Resources/LocalVoice/voice_assets.py`与engine-assets.json、Core LocalVoiceEngine；扩展ChatPersistence/ChatFixtures的只读引擎状态；新增`Tests/LocalVoice/test_prepare.py`和Core引擎描述测试，登记资源。

**Interfaces:** CLI提供`prepare --experiment PATH --python PATH --settings-path PATH`、`export-voice --experiment PATH --candidate e1 --output PATH`、`check --settings-path PATH`。Python共享`verify_assets(root:Path,manifest:dict)->None`；Swift`LocalVoiceEngineDescriptor.load(dataRoot:URL) throws -> LocalVoiceEngineDescriptor`解析Engine/current.json中的版本UUID/profile/architecture/pythonVersion/sourceCommit及相对配置，`resolve(dataRoot:URL) throws -> LocalVoiceEngineConfiguration`返回固定版本内的pythonURL/sourceURL/cacheURL与资产清单。Core的`LocalVoiceEngineStatus`为unconfigured/configured(profile:String)/unavailable(message:String)；ChatPersisting新增`localVoiceEngineStatus() async -> LocalVoiceEngineStatus`，ChatArchiveWorker及ControlledChatPersistence只读解析描述，不启动Python；configured不等于已发声。

- [ ] **Step 1: 写失败断言。** `test_new_venv_is_created_at_final_version_path`、`test_failed_prepare_keeps_previous_current_descriptor`、`test_export_e1_preserves_known_weight_and_reference_digests`、`test_check_never_installs_or_loads_model`。用假安装命令/小模型摘要表验证参数与激活顺序；无需ML、网络或真实venv。
- [ ] **Step 2: 观察RED。** `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/LocalVoice -p 'test_prepare.py' -v`；`bash scripts/test.sh -only-testing:PetCoreTests/LocalVoiceEngineTests`。
- [ ] **Step 3: 实现显式准备工具。** 从固定archive/SHA验证并展开原源码，按清单复制仅必需公共资源，引用已保存候选摘要；不修改原实验。新UUID最终路径创建Python3.12环境、固定依赖安装和导入检查，成功后原子切换current.json，不移动已创建venv。检查准确目标App/worker已退出，不按名字杀进程；失败版本不启用，旧版保留。导出三文件胡桃e1文件夹，使用现有prepared WAV，不需要FFmpeg或加载权重。资产/引擎描述只含运行路径/版本/摘要，不含私人配置；源模型/代码不随App打包。
- [ ] **Step 4: 验证GREEN及早期环境事实。** 跑上述离线测试；再在仓库外独立验证根（`/Users/resker/develop/YeShunguangPet-local-voice-validation/<run-id>/settings.json`）运行prepare，使用已核对的Homebrew Python3.12路径，新环境仅验证必要模块/版本可导入。显式准备允许下载依赖，可用缓存；出现解析/构建失败保留日志再修正有证据的版本约束，不改原venv、不谎称freeze已重建。导出`dist/语音包/胡桃-试用-e1/`，校验原权重/参考SHA和上游源文件不变。本步不替换个人App或写其AI。
- [ ] **Step 5: 本地提交。** `build: prepare a versioned M4 voice runtime and export Hu Tao package`；仅提交工具、元数据与测试，原依赖/模型仍忽略。

### Task 4: 有界stdio worker与固定GPT-SoVITS适配

**Files:** 新增`Resources/LocalVoice/{worker_protocol,gpt_sovits_backend,worker}.py`；新增`Tests/LocalVoice/{test_worker_protocol,test_worker_lifecycle,test_backend_config}.py`。

**Interfaces:** `decode_command(line:bytes)->dict`严格解析v1；`serve(reader,writer,backend_factory)->int`可注入替身。真实`GPTSoVITSBackend(engine_root:Path,voice_root:Path,work_root:Path)`提供`initialize()->None`和`generate(text:str,speed_factor:float,output:Path)->dict`。启动argv仅固定engine/voice/work路径与sessionID；ready事件含v/event/sessionID/profile。generate命令含v/command/sessionID/requestID/text/speedFactor；result只含v/event/sessionID/requestID/sampleRate/frames，文件固定work/<requestID>.wav；error只回白名单code，shutdown无文字。

- [ ] **Step 1: 写失败断言。** `test_stdout_contains_protocol_only_even_when_backend_prints`、`test_partial_or_oversize_line_is_bounded`、`test_eof_exits_during_blocked_initialization`、`test_invalid_request_never_calls_backend`、`test_all_zh_config_and_temp_yaml_do_not_mutate_upstream`。替身只输出小PCM；子进程测试按真实ready/exit事件限时等待，不靠固定sleep猜测完成。
- [ ] **Step 2: 观察RED。** `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/LocalVoice -p 'test_worker*.py' -v`及`test_backend_config.py`对应命令；预期缺少协议/worker或断言失败。
- [ ] **Step 3: 实现协议与适配。** stdin受限接收线程先于重型导入启动，父EOF/shutdown可在初始化/计算中终止；stdout保留独立协议句柄，上游输出不污染协议，stderr排空/丢弃不保存聊天。固定离线环境/禁遥测/受控缓存，缺资源失败，测试中网络调用应被拒绝；中文all_zh、cut0、batch1、CPU/float32/4线程、固定profile、关闭CUDA/流式。cfg.configs_path写任务私有目录，按实际安装根映射公共资源。使用已有可信S2与参考文本，生成PCM16，累计帧/文件大小限制后原子交付。backend_factory仅是内部函数注入点，测试用独立helper调用；生产CLI不能接收任意模块或测试后端。离线协议测试用系统python3，不依赖3.12专用语法；真实ML解释器另严格要求3.12。
- [ ] **Step 4: 验证GREEN。** 完整`Tests/LocalVoice`离线套件；断言≤64KiB行、未知字段/重复键/Bool数值/错session、>600文字、0.7/1.3边界、超大/空音频、配置写回、EOF无残留与不记录原输入。真实适配器仅在显式M4验证加载模型，普通测试不得导入torch/触网。
- [ ] **Step 5: 本地提交。** `feat: add a bounded offline character voice worker`。

### Task 5: 异步进程、资源监控与原生播放

**Files:** 新增Mac LocalVoiceProcess/Output/Player，新增`Tests/PetMacTests/{LocalVoiceProcessTests,LocalVoiceOutputTests}.swift`、Support进程/播放器替身与小helper资源。

**Interfaces:** 三个Mac服务协议/对象均为@MainActor门面，阻塞I/O与计算交由后台执行器。`LocalVoiceProcessDriving`提供`start(configuration:LocalVoiceEngineConfiguration,voice:ResolvedLocalVoice,workDirectory:URL,session:UUID) async throws`（等ready）、`generate(requestID:UUID,text:String,speedFactor:Double) async throws -> URL`、`stop() async -> Bool`、`var hasResources:Bool`；真实适配器持有唯一Process。`LocalVoicePlayerDriving.play(data:Data,token:UUID,onEvent:@escaping @MainActor(UUID,LocalVoicePlayerEvent)->Void) throws`、`stop() async -> Bool`、hasResources，PlayerEvent为started/finished/failed。`LocalVoiceOutput.start(_ request:LocalVoiceRequest,onEvent:@escaping @MainActor(UUID,LocalVoiceOutputEvent)->Void) throws`、`prepare(voice:ResolvedLocalVoice) async -> Bool`、`stop() async -> Bool`、hasResources。OutputEvent为phase(LocalVoicePhase)、finished/cancelled/failed(issue:LocalVoiceIssue,playbackStarted:Bool)，LocalVoicePhase为starting/generating/playing；Issue为有界本地错误类别，不装原始trace。Request含token/voice/text/rate；ResolvedLocalVoice消费Task2类型。

- [ ] **Step 1: 写失败断言。** `testReadyFloodOrTimeoutKeepsMainActorResponsiveAndKillsOnlyOwnedPID`、`testStopDuringLaunchGenerationAndPlaybackWaitsForResources`、`testOldExitCannotRetireNewSession`、`testIdleExpiresAt180SecondsWithoutActiveWork`。假时钟/进程可控ready、退出、RSS与停止失败，真实小helper另验证管道与PID隔离。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/LocalVoiceProcessTests -only-testing:PetMacTests/LocalVoiceOutputTests`。
- [ ] **Step 3: 实现独立进程/播放器。** Foundation.Process与FileHandle后台I/O，固定参数数组，不用shell，模型与WAV读取不占MainActor。按session/request路由，协议行64KiB、stdout单请求累计256KiB、stderr累计1MiB越界即终止；持续排空且不持久化正文。ready45秒/生成120秒，启动/生成每500ms采样自己的PID RSS，>8GiB失败；空闲只有一次180秒期限。停止先终止/关播放，2秒后仅SIGKILL准确子进程，再等2秒；句柄确认完成才成功。生成文件验证固定路径/普通文件/32MiB/240秒，创建不可变快照后AVAudioPlayer播放，播放开始状态由真实播放启动边界产生。
- [ ] **Step 4: 验证GREEN。** 同一命令；补齐分片UTF8/坏JSON/重复ready/错ID/无文件/链接/源变化/空音频、计时与RSS越界、停止false可重试、并发stop幂等、旧回调、释放文件、父EOF真实进程退出。`testPrepareReusesOnlyIdleSameVoiceAndStopAlwaysDisposesIt`断言空闲同包可复用，活跃请求/不同包先确认停止；显式stop即使空闲也释放。合成播放器证明边界，不当可闻通过；不得终止测试以外Python。
- [ ] **Step 5: 本地提交。** `feat: manage local voice process and playback lifetimes`。

### Task 6: 共享输出路由、实际来源与一次回退

**Files:** 新增VoiceOutputRouting/Router，修改VoiceServices、ChatVoiceController、现有VoiceFixtures与语音控制器/集成测试；新增`VoiceOutputRouterTests.swift`。

**Interfaces:** 保留NativeSpeechOutput的`VoiceOutputProviding`；新@MainActor `VoiceOutputRouting`提供`installedSystemVoices()->[SystemVoice]`、onVoicesChanged、`prepare(for selection:VoiceRouteSelection) async -> Bool`、`speak(_ request:RoutedVoiceRequest,onEvent:@escaping @MainActor(UUID,RoutedVoiceEvent)->Void) throws`、`stop() async -> Bool`及hasResources。Request含token/text/rate/preferredSystemVoiceID/selection；`VoiceRouteSelection`为system/local(ResolvedLocalVoice)/unavailable(LocalVoiceIssue)。`RoutedVoiceEvent`提供phase(VoiceOutputPhase)、actualIdentity(VoiceOutputIdentity)、notice(String)、finished/cancelled/failed(LocalVoiceIssue)，Phase为idle/resolving/starting/generating/playing/stopping；Identity包含backend/displayName及可选系统ID或库UUID。ChatVoiceController增加`resolveSelection:(ChatCharacter) async -> VoiceRouteSelection`注入点，默认system；公开outputPhase/hasOutputActivity/actualOutput/hasPendingResources及`stopAndWait() async -> Bool`（等待已有停止，否则发起完整停止并等待），录音接口保持。

- [ ] **Step 1: 写失败断言。** `testLocalOutputStartsWithNoInstalledAppleVoice`、`testPrePlaybackFailureFallsBackOnceAfterConfirmedStop`、`testCancelOrPlaybackFailureNeverFallsBack`、`testSameIDNewSkinOrSynchronousHideFencesFallback`、`testManualLongLocalReplyUsesSystemWithoutTruncation`。断言600/601/8000/8001、默认speed1.0与0.7/1.3、绑定与系统偏好不被回退改写。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/VoiceOutputRouterTests -only-testing:PetMacTests/ChatVoiceControllerTests -only-testing:PetMacTests/ChatVoiceIntegrationTests`。
- [ ] **Step 3: 实现路由与上下文屏障。** local先决策而非先guard系统音色；本地失败仅在未播放/意图仍有效/stop成功时一次系统回退。>600手动长文在播放前清楚通知并走系统全文。新朗读先撤销旧活跃意图并等待已有停止，再异步解析绑定并调用prepare；已确认空闲同角色worker可复用，不因现有read无条件stop路径而每句重载。显式停止、录音前、阻挡/角色变化/睡眠/退出仍调用完整stop，包括空闲worker。发布状态和调用服务前后复查完整角色/skinRevision、commandRevision与环境；hasOutputActivity覆盖启动/生成/播放，hasPendingResources额外包含空闲worker与停止任务。系统音色变化只影响system actualIdentity；原保存后一次与无补播规则保持。
- [ ] **Step 4: 验证GREEN。** 上述命令及NativeSpeechOutput相关既有测试；失败回退时再停、无系统音色、输出stop false、录音前权限零请求、重复stop、@Published同步订阅重入、设置禁用失败重试均断言不产生多余发声/API/保存。沿用ControlledVoiceOutput作为系统替身，新增路由替身，不把原系统测试全部绕开。
- [ ] **Step 5: 本地提交。** `feat: route role speech with cancellable system fallback`。

### Task 7: 唯一语音库控制器、确认与角色绑定界面

**Files:** 新增ChatLocalVoiceController/SettingsView；修改ChatVoiceSettingsView与ChatController语音组合点；新增`ChatLocalVoiceControllerTests.swift`、`LocalVoiceWindowTests.swift`。

**Interfaces:** `ChatLocalVoiceController(persistence:any ChatPersisting,writes:ChatWriteQueue,context:()->ChatCharacter?,canMutate:()->Bool,stopOutput:() async -> Bool)`公开index/entries/preview/engineStatus/error/isBusy/hasPendingMutation/terminationError；提供`preview(folder:URL)`、`confirmImport()`、`cancelPreview()`、`applyBinding(_ id:UUID?,expected:ChatCharacter)`、`delete(_ id:UUID)`、`retryPendingSave()`、`retryPendingForTermination()`、`backupAndReset()`、`resolve(for:ChatCharacter) async -> VoiceRouteSelection`、`beginTermination()`、`waitForPendingMutations() async`、`dispose()`。stopOutput消费Task6.stopAndWait；在ChatController用弱引用接到voice，避免库/语音互相强持有。初始索引load未完成时resolve等待并重查上下文；protected/坏绑定返回unavailable原因而不静默当未绑定。

- [ ] **Step 1: 写失败断言。** `testImportConfirmDoesNotBindEnableOrSpeak`、`testBindingCommitsBeforeOutputSelectionChanges`、`testLateIndexLoadAndSameIDRevisionCannotApplyToWrongRole`、`testCloseAfterAcceptedImportKeepsFIFOTransaction`、`testFailedSaveAndCleanupRemainRetryableAtExit`，覆盖相同内容复用与已绑定删除拒绝。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/ChatLocalVoiceControllerTests -only-testing:PetMacTests/LocalVoiceWindowTests`。
- [ ] **Step 3: 实现共享模型和页内UI。** ChatController持有唯一localVoices，复用同一writes，两个窗口只展示；语音设置页增加引擎“未配置/已配置待首次检查/失败”、当前角色下拉、独立“应用当前角色音色”、导入预览确认/删除确认/刷新/受保护重置。文件面板只选文件夹；活跃生成/播放时不变更，开始模型变更前先通过停止屏障释放空闲worker，再复查实际角色与忙碌状态。关闭取消未确认任务，已接受写入持有stage直至完成；pending save与cleanup重试不加载模型、不发声。系统语音原应用控件继续独立。
- [ ] **Step 4: 验证GREEN。** 上述命令及`ChatVoiceWindowTests`；原生440×420浅深色/滚动与长名同名坏包、按钮可达、设置sheet、marked text和模型忙碌。正常取消/放弃预览清私有临时目录，清理失败可见；正常重开读取绑定，不改voice.json、AI角色档案或原素材。渲染/程序化点击不当物理验收。
- [ ] **Step 5: 本地提交。** `feat: manage local voice imports and explicit role bindings`。

### Task 8: 生产装配、双窗状态、退出资源与CI打包边界

**Files:** 修改StatusBarController、AppDelegate、ChatController、ChatVoiceControls/SettingsView、Info.plist、Xcode资源登记；新增`LocalVoiceProductionIntegrationTests.swift`，扩展ChatLifecycle/VoiceProductionIntegration；修改`.github/workflows/macos-build.yml`、verify-app.py、Distribution相关测试与帮助说明。

**Interfaces:** StatusBar按session.settings.url组合固定worker URL/LocalVoiceOutput/VoiceOutputRouter，绑定Task7.resolve，不修改输入NativeSpeechInput。ChatController新增`hasPendingTerminationResources:Bool`、`waitForTerminationResources() async -> Bool`、`retryTerminationResources() async -> Bool`及`terminationResourceError:String?`；磁盘hasPendingWrites原义保持。AppDelegate在terminateLater等待模型事务、磁盘FIFO和语音屏障，再分别确认保存/资源失败，支持重试/取消/明确继续退出；取消不重启旧声音。

- [ ] **Step 1: 写失败断言。** `testExitWaitsForInitializingWorkerWhenWriteQueueIsEmpty`、`testFailedStopRetryOrCancelledExitNeverResumes`、`testQuickFullHandoffPreservesOneWorkerAndActualSource`、`testMissingRuntimeDoesNotBreakTextOrSystemSpeech`、`testPackagedAdapterIsCompleteAndContainsNoWeightsOrVenv`。使用新异步终止协调边界/假NSApp回复，不让测试退出宿主；保留已有sheet阻止退出断言。
- [ ] **Step 2: 观察RED。** `bash scripts/test.sh -only-testing:PetMacTests/LocalVoiceProductionIntegrationTests -only-testing:PetMacTests/ChatLifecycleTests -only-testing:PetMacTests/VoiceProductionIntegrationTests`；新增分发断言首次在对应包不含适配器时可观察失败，不用旧包版本推定新包通过。
- [ ] **Step 3: 装配生产与构建。** 双窗统一展示starting/generating/playing/stopping与实际来源/回退notice；菜单/模态/隐藏/离页/换肤/安静/睡眠沿用同一取消环境。退出额外等资源，pending local index/cleanup加入原失败选择；取消退出不恢复请求。Info.plist设0.6.0/build29。CI新增stdlib LocalVoice离线套件，设PYTHONDONTWRITEBYTECODE=1；不安装ML/下载模型。verify-app验证4份适配器+engine-assets.json存在且资源目录无额外文件/pycache；ZIP/DMG自动全库存比较与缺资源/含权重的拒绝回归覆盖两架构。
- [ ] **Step 4: 验证GREEN。** 上述定向、完整LocalVoice离线及Release离线；在两个新架构App构建后运行分发测试。断言仅隐藏桌宠继续、完整/轻窗交接无中间取消、物理权限未触发、Keychain/API零正式调用，原schema13/v2/voice1字节与原图片SHA保持。停止失败错误不沿用“系统朗读”误指本地来源。
- [ ] **Step 5: 本地提交。** `feat: integrate local character voice and wait for engine shutdown`。

### Task 9: 整体回归、一次最终评审、真实M4引擎与本地交付

**Files:** 完成`docs/local-character-voice-validation.md`、README/TODO/AGENTS与使用说明；测试/修复限本功能；真实日志、音频、包与性能数据只进忽略目录或明确本机运行目录。

**Interfaces:** 消费全部前述接口；最终证据记录源码commit、引擎版本/依赖、语音包SHA、冷启动/生成时长、实际PCM、峰值RSS、停止耗时/退出状态、双架构包来源与用户待验项目。不得从“文件存在”“属性为真”推断实际发声/停止。

- [ ] **Step 1: 完整自动回归。** `bash scripts/test.sh`、`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/LocalVoice -v`、`python3 -m unittest discover -s Tests/Release -v`；保存完整日志/返回码/实际数量。失败先定位，修复必须针对真实失败回归，不新增无意义镜像测试。
- [ ] **Step 2: 当前M4实测独立环境与输出。** 使用Task3仓库外隔离根及明确测试文本，通过真实适配器/Native输出链验证新中文句子；测cold ready、首条/后续生成、PCM全解码、RSS。分别在初始化/生成/播放中取消，检查自己的准确PID退出、无晚播/回退、UI RunLoop可调度；测父管道关闭、超时与空闲释放。原生播放启动/音频解码与实际可闻分列，可闻由用户试听反馈确认。不能为了让App加载旧实验模块而改全局PYTHONPATH或个人Python。
- [ ] **Step 3: 一次最终独立整体代码评审。** 按已选Native方式，在完整功能与回归后对设计基线至当前分支作一次新整体只读评审，覆盖任务文件、协议、取消/FIFO/索引/引擎准备和测试盲区。保留真实评审结果；Critical/Important先失败回归后修复，同一评审席位必要澄清，不额外开逐任务或第二次独立整体评审。非阻断项明确列TODO，不能宣称零问题。
- [ ] **Step 4: 干净来源双架构包。** 代码/测试修复验证并提交后，从干净commit运行`bash scripts/build-app.sh arm64`、`bash scripts/build-app.sh x86_64`、`python3 -m unittest discover -s Tests/Distribution -v`、`bash scripts/package-app.sh arm64`和x86_64同命令；八附件离线check-only沿用现有prepare-release入口，不创建草稿。核对14.0、签名/资源/原皮肤/适配器/库存/依赖/版本/来源/摘要，ARM真正中文空格路径搬移、弹出DMG后独立重开；无引擎安装场景也通过。交叉构建不当Intel引擎实机通过。
- [ ] **Step 5: 本机日用交付。** 按准确路径正常退出旧0.5.1并等待结束，盲备份旧App/主配置/完整AI，只比较必要元数据/摘要；不解析私人聊天/Keychain，不改登录项。在正式settingsURL同级最终位置再次显式准备独立引擎，复用已验证依赖缓存但不搬移venv；确认成功才安装干净ARM App并核对旧状态。提供可见胡桃e1包让用户主动导入/绑定/试听，不自动为用户启用语音或绑定角色。保留e2与所有原实验/备份。记录真实失败/未测，最后提交交付文档；无push/tag/Release。

## 自审与执行交接

主执行者完成计划自审，不另派计划评审：设计1/2对应Task6–9，布局/环境对应Task2–5，包与绑定对应Task1/2/7，朗读/回退对应Task6，进程与播放对应Task4/5/8，UI/生命周期对应Task7/8，完整验证交付对应Task9。五项Review Focus都有指定用例；步骤分别可检验，跨任务类型/函数在Interfaces中定义，未用“稍后决定”替代外部合同。

状态：当前只保存设计批准记录与本计划，没有运行新测试、安装依赖、加载模型或修改日用App。待用户审核计划后，使用已经选择的本会话主执行者原地实施，不再要求重选执行方式。仅在计划批准后建立本计划独立ledger：`.superpowers/sdd/2026-10-27-macos-local-character-voice/progress.md`；已完成任务不重做，不恢复旧0.5.0/0.5.1或其他计划。后续使用superpowers:executing-plans连续实施与本地提交，保留一次最终独立整体评审；新远端写入仍需用户明确指令。
