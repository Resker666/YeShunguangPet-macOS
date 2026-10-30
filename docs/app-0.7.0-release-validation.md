# 0.7.0 App 发布准备与推送核验

日期：2026-10-30（Asia/Shanghai）。普通App发行与已公开的`voice-assets-v1.0.0`分别管理。实现阶段按用户指令推送代码，随后由用户自行触发草稿流程并公开发布；下面保留完整验证历史。

## 当前公开状态

[v0.7.0](https://github.com/Resker666/YeShunguangPet-macOS/releases/tag/v0.7.0)已于2026-10-30公开并设为Latest，Release ID为428622639；实际标签、正文来源标记和安装包来源均为`3d2d2b9c09afc200c7cc53497a5dd5f45810220d`。用户手动发版工作流[40996662356](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40996662356)的构建与草稿任务均成功，最终由用户网页公开。独立语音资源仍为六附件预发布，App更新通常无需重下引擎和音色。

已不带凭据或Cookie实际匿名重新下载八附件，共30,502,501字节；全部大小/SHA256、摘要文件内容、ZIP中的0.7.0版本及干净源码来源核对通过。下载后再次核对同一Release、Latest、实际标签及八份附件ID/大小/摘要一致。下载与证据保存在`.build/app-release-070-validation/anonymous-v0.7.0-20261030/`和`user-publication-final-verification.json`。这次公开下载检查没有运行App，不扩展为外机或Gatekeeper首开验收。

最终源码两路push CI为主干[40988509350](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40988509350)第二次、开发分支[40988509158](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40988509158)首次，均598原生/52Release/38LocalVoice/17分发及双架构上传通过。主干首次在Intel临时DMG校验时收到`Resource temporarily unavailable`，保留原始失败；同源重跑通过，没有修改hdiutil代码或降低断言，首次资源错误根因未确认。

发布后的同步仅更新Markdown下载入口和状态，不重建App，不改变`v0.7.0`标签、发行附件或语音资源。

## 首次推送与真实失败

已将发布准备提交`9d85dcd0fd973f926fabc9bedd91c51fb93b9062`普通原子推送至`main`和`codex/macos-app-070-release`。主干[40986303306](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40986303306)首次成功，597原生（192Core/405Mac）、52Release、38LocalVoice、17分发及两架构构建/打包/来源核验和上传通过，草稿跳过。

开发分支[40986303448](https://github.com/Resker666/YeShunguangPet-macOS/actions/runs/40986303448)首次原生失败，52Release/38LocalVoice通过，安装包未生成。实际xcresult确认两项失败：

- `LocalVoiceProcessTests.testWrongIDsAndGenerationTimeoutAreRejected`：测试进程收到SIGPIPE退出。导出会话日志记录“Test crashed with signal pipe”；原始job文本只显示重启，不能仅凭该文本称为测试超时，也未取得第一处写调用的堆栈。
- `LocalVoiceProductionIntegrationTests.testGeneratingControlsOfferStopAndDescribeLocalPhase`：前一进程退出后，重启的测试进程在`NSApp.sendAction`处因NSApp为空崩溃；测试隐式依赖其他用例先初始化NSApplication。

保存首次完整日志、103,408,170字节诊断包、导出会话日志和结构化失败摘要，位置为`.build/app-release-070-validation/feature-attempt1-*`。诊断包SHA256为`36e70f979eec6ddb27b51fd8fcd7b7e087a3734dddd299a722a03a351786aaf4`。同一旧提交的一次失败任务重跑只用于判断可重复性；即使重跑通过也不能证明SIGPIPE问题已修复。

## 最小修复与验证

新增真实stdio回归：受控Python子进程在ready之前关闭stdin，仍保持运行；App尝试生成时必须返回现有不可用错误并正常清理，不能由SIGPIPE终止宿主。测试临时恢复默认SIGPIPE处理以避免XCTest宿主继承忽略设置导致漏检，结束后恢复原设置；未使用真实模型、音频、个人AI或钥匙串。

修复前实际RED：该回归退出65，xcresult明确记录`Test crashed with signal pipe`。修复只对本次worker输入管道设置`F_SETNOSIGPIPE`，失败时走现有不可用/清理分支，不改变App全局信号处理。Apple的[fcntl说明](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/fcntl.2)定义此选项可将无读取者的管道写入失败保留为错误返回，避免产生SIGPIPE。

同时在产生界面操作的测试中显式初始化NSApplication，保持生产UI行为不变。相关进程与生产集成12项GREEN，完整598项原生（192Core/406Mac）通过。修复来源`e5f8b8f04e5777fffb0478d9cb776b829ea6a94f`的两架构本地构建/打包和八附件离线check-only通过；本轮后续仅文档提交不改变其功能代码，最终云端附件必须以自身build-info记录的准确提交为准。

一次新gpt-6-astra/high独立整体评审完成`9d85dcd..e5f8b8f`：0 Critical / 0 Important / 0 Minor，无第二次独立评审、无评审后功能修改。最终新提交云端结果保存在`.build/app-release-070-validation/push-verification.json`，不把旧9d85dcd构建作为修复版。

## 评审判断与代价

- 本次不重构既有begin拒绝后的任务提交或全部启动/写入/关闭并发机制。评审未发现本改动带来的新问题；代价是这次有界修复不宣称解决全部进程并发风险，有新的实际证据再定位。
- 首次CI只有SIGPIPE信号，没有原始写调用堆栈。因此只确认新回归证明的真实管道故障机制及其修正，不能把推测的精确首次调用写成事实；保留原报告。
- 本次继续完成新提交CI与发行包核验；实机模型/可闻声音、个人App安装、macOS14和Intel等不由代码评审或交叉构建推定通过。日用App不因本轮推送而自动更新。

App版本仍0.7.0/build30，主配置schema13、角色档案v2、语音偏好和引擎协议不变；公共引擎与音色无需重制。日用App、个人资料及登录项保持不变。旧本地包和云端包继续保留，最终发布前必须使用含修复提交的八附件与对应来源正文。

本次尚不构成Intel运行、macOS14或其他Mac/Gatekeeper首开验证；既有外机与系统场景限制保持。
