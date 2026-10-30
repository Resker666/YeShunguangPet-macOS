# 0.7.0 App 发布准备与推送核验

日期：2026-10-30（Asia/Shanghai）。普通App发行与已公开的`voice-assets-v1.0.0`分别管理。本轮用户已明确授权推送，未授权标签、Release草稿或公开发布。

## 首次推送与真实失败

已将发布准备提交`9d85dcd0fd973f926fabc9bedd91c51fb93b9062`普通原子推送至`main`和`codex/macos-app-070-release`。主干[40986303306](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40986303306)首次成功，597原生（192Core/405Mac）、52Release、38LocalVoice、17分发及两架构构建/打包/来源核验和上传通过，草稿跳过。

开发分支[40986303448](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40986303448)首次原生失败，52Release/38LocalVoice通过，安装包未生成。实际xcresult确认两项失败：

- `LocalVoiceProcessTests.testWrongIDsAndGenerationTimeoutAreRejected`：测试进程收到SIGPIPE退出。导出会话日志记录“Test crashed with signal pipe”；原始job文本只显示重启，不能仅凭该文本称为测试超时，也未取得第一处写调用的堆栈。
- `LocalVoiceProductionIntegrationTests.testGeneratingControlsOfferStopAndDescribeLocalPhase`：前一进程退出后，重启的测试进程在`NSApp.sendAction`处因NSApp为空崩溃；测试隐式依赖其他用例先初始化NSApplication。

保存首次完整日志、103,408,170字节诊断包、导出会话日志和结构化失败摘要，位置为`.build/app-release-070-validation/feature-attempt1-*`。诊断包SHA256为`36e70f979eec6ddb27b51fd8fcd7b7e087a3734dddd299a722a03a351786aaf4`。同一旧提交的一次失败任务重跑只用于判断可重复性；即使重跑通过也不能证明SIGPIPE问题已修复。

## 最小修复与验证

新增真实stdio回归：受控Python子进程在ready之前关闭stdin，仍保持运行；App尝试生成时必须返回现有不可用错误并正常清理，不能由SIGPIPE终止宿主。测试临时恢复默认SIGPIPE处理以避免XCTest宿主继承忽略设置导致漏检，结束后恢复原设置；未使用真实模型、音频、个人AI或钥匙串。

修复前实际RED：该回归退出65，xcresult明确记录`Test crashed with signal pipe`。修复只对本次worker输入管道设置`F_SETNOSIGPIPE`，失败时走现有不可用/清理分支，不改变App全局信号处理。Apple的[fcntl说明](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/fcntl.2)定义此选项可将无读取者的管道写入失败保留为错误返回，避免产生SIGPIPE。

同时在产生界面操作的测试中显式初始化NSApplication，保持生产UI行为不变。相关进程与生产集成12项GREEN；完整原生、独立评审和最终新提交云端结果以实际证据追加，不把旧9d85dcd构建作为修复版。

App版本仍0.7.0/build30，主配置schema13、角色档案v2、语音偏好和引擎协议不变；公共引擎与音色无需重制。日用App、个人资料及登录项保持不变。旧本地包和云端包继续保留，最终发布前必须使用含修复提交的八附件与对应来源正文。

本次尚不构成Intel运行、macOS14或其他Mac/Gatekeeper首开验证；既有外机与系统场景限制保持。
