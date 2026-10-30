# 独立语音资源下载与安装

2026-10-29：[本地语音资源1.0.0（M系列预览）](https://github.com/Resker666/YeShunguangPet-macOS/releases/tag/voice-assets-v1.0.0)已公开，六附件均已匿名重新下载并核对大小/SHA256。无需登录即可下载资源。标签`voice-assets-v1.0.0`固定到工具来源`9c89d47`，为独立预发布，普通App更新与资源版本分别管理。

需要App **0.7.0/build30或后续兼容版**、M系列Mac，以及两份资源：

App0.7.0已[公开发布并设为Latest](https://github.com/Resker666/YeShunguangPet-macOS/releases/tag/v0.7.0)，可直接下载[M系列App DMG](https://github.com/Resker666/YeShunguangPet-macOS/releases/download/v0.7.0/YeShunguangPet-0.7.0-macOS-arm64.dmg)，无需登录GitHub。先安装App，再安装下列引擎和音色；App、引擎与音色分别管理版本，公开Release下载不依赖Actions产物的14天保留期。

| 下载 | 用途 |
| --- | --- |
| [引擎DMG](https://github.com/Resker666/YeShunguangPet-macOS/releases/download/voice-assets-v1.0.0/YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg) · [SHA256](https://github.com/Resker666/YeShunguangPet-macOS/releases/download/voice-assets-v1.0.0/YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg.sha256) | 公共推理引擎，约2.05GB，只需独立安装一次 |
| [胡桃e1 ZIP](https://github.com/Resker666/YeShunguangPet-macOS/releases/download/voice-assets-v1.0.0/YeShunguangPet-Voice-hutao-pilot-e1.zip) · [SHA256](https://github.com/Resker666/YeShunguangPet-macOS/releases/download/voice-assets-v1.0.0/YeShunguangPet-Voice-hutao-pilot-e1.zip.sha256) | 约161MB，先解压后导入三文件目录 |
| [voice-assets.json](https://github.com/Resker666/YeShunguangPet-macOS/releases/download/voice-assets-v1.0.0/voice-assets.json) | 来源、兼容信息和文件摘要 |
| [中文安装说明](https://github.com/Resker666/YeShunguangPet-macOS/releases/download/voice-assets-v1.0.0/voice-installation.md) | 引擎安装、音色导入与启用步骤 |

## 安装引擎

1. 先安装并打开兼容App；安装时无需Xcode、Homebrew或外部Python。
2. 下载引擎DMG和对应摘要文件，在Finder双击打开DMG。
3. 在桌宠菜单打开完整「聊天… → 语音」，点击「安装或修复本地引擎…」。
4. 文件面板左侧选择挂载的「角色语音引擎1.0.0」，进入并选择实际含`engine.json`与`payload`的「本地中文引擎-1.0.0-arm64」文件夹。不要选择存放DMG的下载目录或整个磁盘卷。
5. 预览后点「确认安装引擎」，等待复制和自检成功，再弹出DMG。失败/取消保留旧引擎，修复继续选有效包。

## 导入胡桃音色

1. 下载胡桃ZIP并双击解压，得到「胡桃-试用-e1」文件夹与外层来源说明。
2. 在App语音页导入实际包含`voice.json`、`s2.pth`、`reference.wav`的三文件目录。App当前不直接导入ZIP，不要把外层来源说明移入三文件目录。
3. 为当前角色选择「胡桃 · 试用e1」并应用绑定，主动启用语音，再点击试听或朗读最近回复。导入和绑定不会自动发声。

安装完成后，App使用独立保存的引擎与音色副本，不依赖原下载目录。更新普通App通常无需重下引擎；新角色包可复用兼容引擎。空闲3分钟后引擎会释放，首次启动需等待。

兼容目标macOS14+，真实设备当前仅M4。Intel App可用文字/系统语音，不安装本ARM引擎。App与引擎ad-hoc签名、未公证；下载后的系统首开行为和其他Mac安装需要实际验证。模型/角色来源及未核实项见[来源说明](local-voice-resource-notices.md)，详细恢复方式见[独立引擎说明](local-voice-engine-installation.md)。

## 维护者准备

`tools/package-voice-assets.py`消费已验证的压缩DMG、原始引擎目录与e1，写入独立且不存在的输出目录，保留所有原件。以最终干净工具提交作为`--commit`，不要误用App基线或上游提交。

```sh
python3 tools/package-voice-assets.py \
  --engine-dmg .build/voice-distribution-validation/compression/engine-udzo.dmg \
  --engine-package .build/portable-voice-engine-validation/moved-inputs/final-engine-package \
  --voice dist/语音包/胡桃-试用-e1 \
  --output dist/语音分发/voice-assets-v1.0.0 \
  --commit <完整工具提交> \
  --readme docs/voice-assets-installation.md \
  --notices docs/local-voice-resource-notices.md
python3 scripts/prepare-voice-release.py --assets dist/语音分发/voice-assets-v1.0.0 \
  --version 1.0.0 --commit <同一完整工具提交> --check-only
```

默认检查与`--check-only`完全离线，不读认证。`--prepare-draft`才准备并补传同一资源草稿，`--publish`才显式公开为非Latest的资源预发布；真实模式需要准备好的`--notes`和用户主动提供给本机工具的GitHub认证环境，不在聊天中发送密钥。`--publish --download-to <新的目录>`可在公开后匿名重新下载核验。已有附件或来源冲突不覆盖，网络中断先检查同一草稿；不会自动删除未完成的同名附件。

网页发布接续说明：当前`--prepare-draft`/`--publish`严格核对API元数据，直接接管本次网页发布会因`target_commitish=main`及CRLF正文而拒绝。不要为通过校验而重建或覆盖已公开资源；本次以GitHub实际标签提交和完整正文（仅统一换行）复核，再调用既有匿名下载器，原始响应与解析记录均保留。后续若需CLI接管兼容，另作有界改进。
