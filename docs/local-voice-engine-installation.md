# 独立本地语音引擎

0.7.0 功能开发中；最终安装、自检和交付结果以验证记录为准。普通 App、公共引擎和角色音色包分开保存，更新 App 不会自动重装引擎。

## 使用者安装流程

1. 在 Apple Silicon Mac 上打开独立引擎 DMG。首版只提供 arm64；macOS 14+为目标，当前真实设备验证仅覆盖 M4。
2. 在完整聊天窗的语音页选择“安装或修复本地引擎…”，选取磁盘卷内的引擎文件夹，而非整个磁盘卷或角色音色文件夹。
3. 核对包名、版本和占用，再确认安装。引擎含本地可执行代码，选择自己信任的来源；摘要校验只证明文件完整性。
4. 等待复制与自检完成；随后可以弹出 DMG、删除原下载文件。安装过程不需要使用者安装 Python、Homebrew、Xcode 或输入终端命令。
5. 胡桃等音色仍需另行导入语音包，并手动绑定角色、启用语音及试听；安装引擎本身不发声或改变这些偏好。

取消、复制/校验/自检失败不会切换旧引擎。保存失败可仅重试本地切换；修复时重新选择有效引擎包。旧引擎目录保留，不做自动清理。强退或断电可能留下未启用副本占用磁盘空间，不能把正常取消的清理保证扩展到断电。

App 和引擎未进行 Developer ID 公证；遇到系统阻止启动时按实际系统提示处理，App 不自动清除下载隔离属性。另一台 Mac 的 Gatekeeper 首开、macOS 14 实机以及其他 M 系列仍需要独立验证。Intel App 可继续文字聊天/系统语音，不安装本 ARM 引擎。

## 开发侧准备与打包

只在开发机运行下列工具；普通 App/CI 不调用这些步骤。当前锁记录的源码构建工具链为 Xcode 27.0 / SDK 27.0，部署目标14.0；不同工具链产生不同摘要时应重新审计并记录，不能忽略校验失败。

```sh
python3 tools/local_voice_runtime.py --lock tools/local-voice-runtime-m4.json --build-root .build/new-portable-engine
python3 tools/local_voice_macho.py .build/new-portable-engine/runtime
python3 tools/package-local-voice-engine.py \
  --runtime .build/new-portable-engine/runtime \
  --experiment .build/local-role-voice-hutao \
  --output dist/引擎包/本地中文引擎-1.0.0-arm64 \
  --version 1.0.0 \
  --dmg dist/引擎包/YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg
```

工具拒绝覆盖已有输出。Python发行包、103个官方wheel、3个源码包及本机构建wheel的版本/摘要固定；源码wheel使用固定时间与无调试符号的编译参数，保留当前macOS加载需要的UUID，并已在两个构建目录验证可重建。

本CPU中文profile沿用106个依赖版本，保留SoundFile读取固定PCM参考音频；不带需要额外FFmpeg/SoX库的8个可选原生桥接模块。Numba/torchaudio的必要加载路径指向包内Torch库并重新签名，不依赖开发机库目录。运行时的标准库`venv`代码不是旧机器的venv运行环境；本包不包含指向外部Python的虚拟环境。

引擎包只包含`engine.json`与`payload/`；角色S2、参考录音、训练素材和实验路径信息不进入公共资产清单。第三方许可、来源和未核实的checkpoint权利说明随包保留，见[模型记录](local-voice-engine-model-notices.md)。模型、Python、DMG、缓存及生成音频不进入Git；源码/小清单进入Git，公开上传仍需另外授权。

## 旧环境与回退

已有0.6.0描述和引擎继续读取，App不会自动迁移。新引擎使用版本目录及schema2描述，旧App不能读取schema2；需要回到旧App时，先完整退出新App，再恢复安装前备份的原`current.json`，并保留其所指旧版本目录。不要只改UUID猜测版本，也不要把旧venv搬到新路径。实际备份/恢复文件名及失败处理由安装交付记录给出。

安装目录为设置文件同级的 `LocalVoice/Engine/Versions/<UUID>`。成功切换前，旧的普通 `current.json` 原字节备份到 `LocalVoice/Engine/Backups/current-<新UUID>.json`；若原描述不存在则没有这份备份。恢复前退出全部 App/引擎进程，把对应备份复制回 `LocalVoice/Engine/current.json`，保留原版本目录。未知或损坏的旧描述也会原样备份，备份不意味着它本身有效。链接或超过16KiB的旧描述会阻止覆盖，需要先由使用者检查。

引擎1.0.0当前本地DMG约2.30GB，展开内容约3.01GB。安装要求可用空间至少为新内容总量加 `max(256MiB, 10%)`，并保留原有引擎；复制仍可能因实际磁盘错误失败。保存失败时使用“重试引擎切换或清理”；显式取消只移除本次未启用UUID，旧版本不会自动删除。等待切换重试时旧引擎可以继续使用；其他进程改变current后会拒绝覆盖。
