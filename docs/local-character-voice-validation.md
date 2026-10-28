# 0.6.0 本地角色语音验证

日期：2026-10-28。范围是当前 Mac mini M4，独立本机 Python 3.12 引擎与胡桃 S2 e1 候选。通用引擎安装包、Intel 引擎与模型公开分发不在本版范围；没有 push、标签或 Release 授权。

## 功能与数据

App 仍只链接系统框架。四份 Python 适配器和小体积公共资源清单随 App 分发，权重、参考录音、上游源码和 venv 不进入 Git、App 或 CI 附件。运行时通过 stdio 离线生成整条 WAV，不监听端口、不调用云端语音、不增加 DeepSeek 请求。

语音页导入可信文件夹，校验并复制为私有快照，确认登记后再为当前角色应用绑定。导入不启用、不绑定、不加载模型、不发声；绑定先保存再生效，系统音色偏好独立保留。包内只有 voice.json、s2.pth、reference.wav，摘要验证不等于开发者身份认证；pth 只应来自可信来源。单次本地文字最多 600 UTF-16；主动朗读更长回复会提示并用系统音色读全文。正常失败仅在播放前、意图仍有效且停止成功时回退一次。

实际资料目录相对 settings.json 的父目录：LocalVoice/index.json、Voices/UUID、Staging/UUID、Engine/current.json、Engine/Versions/UUID、Cache。引擎 use.lock 由 worker 共享持有、准备事务排他持有，防止切换与模型工作竞争。缺失引擎的普通启动不安装依赖、不创建目录。主 schema13、聊天档案 v2 和 AI/voice.json schema1 保持。

## 自动验证

功能/测试来源 c8bc5e6：完整 555 项原生（175 Core、380 Mac）、17 项 Python stdlib 离线、13 项离线发版通过。39 项阶段定向覆盖双窗、退出、生成停止控件、路由和清理。Task8 两架构中间 App 的 17 项真实分发检查通过；最终干净来源与安装结果另列，不能把中间构建作为最终交付。

已观察并修复的实际失败包括：管道 FileHandle 延迟短响应、多个停止等待者先于资源状态归零返回、同 ID 皮肤修订与同步隐藏回调竞争、无资源启动进入停止状态、损坏包绕过按钮绑定、生成阶段无停止入口、取消选择触发系统回退、完成后清理失败静默，以及 venv 解释器路径解析导致准备工具漏检活跃引擎。对应回归先失败后通过。播放结束现在等待临时音频清理，再发布终态；失败提示并保留停止重试，不换音色重读。

原生窗口逻辑/最小 440×420、滚动、长同名/损坏项与按钮状态断言通过。主执行者查看了浅深色 cache PNG，但 AppKit 缓存有透明/部分绘制，不能据此确认真实显示对比度。真实鼠标、权限和可闻效果仍需用户验收。测试不访问正式 Keychain、私人聊天正文、真实模型 API 或麦克风。

## 真实 M4 阶段证据

隔离根为 `/Users/resker/develop/YeShunguangPet-local-voice-validation/2026-10-27-060`，最终位置创建的 venv 版本 `BAE96F3B-0269-49FA-9495-3D9F7B4612C6`；arm64 Python 3.12.14、106 个固定依赖，固定上游 b4570b876f5c086819ba84e3215472733c6a7b70 的 186 份 Python 原字节保持。CPU/float32/4线程，不搬移 venv、不使用全局 PYTHONPATH。

通过真实适配器生成两条预先指定的新中文测试句，未使用聊天内容。冷 ready 8.685 秒；首句生成 5.283 秒，音频 4.900 秒/313644 字节；后句生成 2.950 秒，音频 5.380 秒/344364 字节。完整解码为 32 kHz/单声道/16位 PCM，非零数据，返回帧数一致。正常进程峰值 RSS 3892.6 MiB，各阶段观察最高 3986.8 MiB；这是一轮采样，不能当作稳定上限或性能保证。

真实 worker 的 shutdown、初始化/生成中父管道 EOF 和准确 PID TERM 均已退出；本轮停止 0.002–0.209 秒，没有按名字终止其他 Python。活跃真实 worker 的共享锁确实拒绝准备工具的排他锁。原生 LocalVoiceProcess/Output/AVAudioPlayer 链的初始化、生成、播放中停止均确认准确 PID 已退出，MainActor 心跳持续；idle/timeout 正在最后核验。播放启动由真实 AVAudioPlayer 返回值和委托边界记录，不宣称人耳已听到或音色已验收。

原始指标、WAV、探针源与日志只在忽略目录 `.build/local-character-voice-validation`；Task1–8 RED/GREEN 与完整日志在本计划独立 `.superpowers/sdd/2026-10-27-macos-local-character-voice`，收尾时归档到前述忽略目录。

## 当前交付状态与未测

当前仍待一次最终整体评审、干净双架构包、最终分发与个人 App 更新。日用 0.5.1 尚未替换；不得从上述阶段验证推定已交付。后续追加精确来源、备份、安装和状态摘要结果。

可闻音色/发音、实际导入绑定按钮、物理输入、真实麦克风与 Apple 在线识别、DeepSeek、睡眠/锁屏/Spaces、另一台 Mac/Intel 引擎/Gatekeeper、公证和本版云端流水线均未据此验收。旧 0.5 的两项 Minor 仍在 TODO，不在本版声称修复。
