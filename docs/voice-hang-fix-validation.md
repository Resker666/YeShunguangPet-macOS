# 0.5.1 系统音色通知死锁修复

2026-10-26（Asia/Shanghai），用户实际试用0.5.0系统语音后反馈整个桌宠无法响应。基线为已推送的 `0f147fe29020bdc08ca5c40efa79c3df55a95058`；本会话原地排错，不恢复已完成0.5.0计划，不修改Windows仓库，不自动推送、打标签或发布。

## 现场与原因

实际卡住的是 `/Applications/YeShunguangPet.app` 0.5.0/build27，PID40623，macOS27.0。5秒采样中458次均显示主线程在音色变化回调中调用 `AVSpeechSynthesisVoice.speechVoices()`，内部 `axUnsafeForcedSync` 等待TTS工作线程；该线程在发布通知时通过 `NSOperation.waitUntilFinished` 等待主线程。进程仍存活但无法处理点击，不是由CPU忙循环导致。

App将 `availableVoicesDidChangeNotification` 的观察队列设为 `.main`。系统音色查询与后台通知同时发生时，两侧同步等待形成环路。修复将观察队列设为 `nil`，通知原线程只创建异步MainActor任务后返回；UI与音色过滤仍在MainActor，注册仍保持单份并在析构时注销。提取同一注册代码为 `SpeechVoicesObservation`，供真实通知中心的隔离回归使用；不模拟系统朗读或申请权限。

Apple的[通知观察文档](https://developer.apple.com/documentation/foundation/notificationcenter/addobserver(forname:object:queue:using:))说明，queue为nil时回调同步运行在发送线程；本次修复让该回调只排队异步UI更新，不从发送线程同步查询音色或等待UI。

## 已执行验证

- 先保留现场栈 `.build/voice-hang-2026-10-26/live-hang.sample.txt`，未先重启破坏现场。
- RED：保持原 `.main` 注册后，以后台通知生产线程模拟系统工作线程，MainActor有界等待该线程返回；实际6项输出测试中1项失败，`posted.wait` 超时，复现互等。测试有超时，不挂死测试进程。
- GREEN：改为nil后，36项相关输出、控制器、窗口、集成测试通过；新增测试验证后台生产者无需等待MainActor、主线程通知仍异步更新、观察对象释放后注销。原测试只注入假driver，未覆盖真实通知中心与线程交叉，这是此次遗漏。

- 完整原生回归491项（158Core/333Mac），0失败；13项离线发版通过。
- 同一生产输出源码的优化隔离探针实际查询系统音色，枚举18个合规中文音色；连续20次后台通知全部完成并异步刷新，未调用录音/朗读或申请权限。探针有30秒进程外超时，不依赖个人配置。

## 最终本地交付

干净来源 `08c166bc65f5fd1d378ab58f7d38ec4c4cbd5ecd`，0.5.1/build28：arm64与x86_64 Release构建、ad-hoc签名、原素材与系统依赖、最低macOS14.0、双架构DMG/ZIP及摘要通过。14项实际分发测试通过，含中文空格路径复制、弹出DMG后独立运行、正常退出和位置恢复；本版八份文件的离线check-only核对版本、完整SHA及trackedChanges:false通过。没有远端写入。

只针对本次修复 `0f147fe..08c166b` 进行一次独立只读评审：0 Critical / 0 Important / 0 Minor，没有扩大为重新评审0.5.0。通知线程、MainActor闭包、弱引用、注册与注销及回归覆盖通过检查；评审未实测录音、可闻朗读、权限、外机或最终安装，主执行者接受这些仍待实际验证的边界。原0.5.0两项Minor继续保留，不属于本次修复结论。

安装前先盲备份旧0.5.0 App、主配置和完整AI目录。旧PID40623在准确路径核对后无法响应SIGTERM；等待3秒后，仅强制结束该卡死进程，没有把此次退出写作正常退出。结束后另存落盘配置和AI副本，再安装到 `/Applications/YeShunguangPet.app`。卡死时尚未保存的内存草稿不能由本流程恢复。

新0.5.1以原个人状态完成一次启动及正常退出，动画有更新，schema13、全部非位置字段/偏好、更新时位置及AI/voice文件摘要保持；之后重新常驻运行，实际PID45987、准确可执行路径和版本已核对。新的2秒采样显示主线程在正常AppKit事件循环中并处理桌宠计时回调，已离开原TTS互等栈。未登记或撤销登录项，没有解析/输出聊天正文、访问正式钥匙串、调用真实API、录音或朗读。

全部原始栈、RED/GREEN/完整测试、只读探针、评审、构建/打包、安装结果与0700私人备份保存在忽略目录 `.build/voice-hang-2026-10-26`。本地安装包为 `dist/YeShunguangPet-0.5.1-macOS-arm64.dmg` 与 `dist/YeShunguangPet-0.5.1-macOS-x86_64.dmg`，另有ZIP和摘要。文档收尾提交不改变包和已安装App的08c166b来源。

语音识别、可闻朗读、权限弹窗以及本版Intel/外机/Gatekeeper、云端Swift6.3.3构建仍待实际验证；只读系统音色查询和修复线程回归不当作整条真实语音链路通过。用户本轮只要求本地排错修复，没有推送、标签或Release授权，main与远端未改。

## 用户验收与推送授权（2026-10-26）

用户随后反馈「可以，通过，推送」，确认0.5.1本机修复整体体验并明确授权按既有流程普通快进同步main和codex/macos-system-voice-chat，核对两路Actions及双架构Artifacts。该整体反馈不扩展为权限撤销/Apple联网/全部设备和语音路径/物理输入/系统/Intel或外机逐项通过；原两项Minor保留。不触发prepare_release、不打标签、不创建草稿或发布Release。

本轮仅记录验收及同步授权，产品、测试、脚本与工程相对08c166b未再变化，不重复491项已通过的本地测试，不替换或操作当前日用App、音频、个人AI与钥匙串。实际远端与CI日志/附件元数据另存忽略目录 `.build/voice-hang-2026-10-26/push-verification.json`，不把授权写作推送或云端验证已成功。
