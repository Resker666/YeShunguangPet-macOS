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

双架构构建、分发和安装以随后实际结果补记，不将相关测试或调用栈定位当作最终交付成功。语音识别、可闻朗读和权限弹窗仍须用户主动体验；不使用个人聊天正文、正式钥匙串或真实DeepSeek作自动回归。
