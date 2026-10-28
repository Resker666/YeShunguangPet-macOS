# 当前 M4 本地角色音色

0.6.0 首版先服务本机。普通 App 可以独立运行，角色音色还需要单独准备引擎和导入语音包；其他 Mac、Intel 与免 Python 安装包后续处理。

## 本机体验

1. 从菜单打开完整聊天，进入“语音”页。确认引擎显示已配置。
2. 选择文件夹 `dist/语音包/胡桃-试用-e1`（Finder 可直接看到 dist），查看预览并确认导入。
3. 为当前角色选择“胡桃 · 试用 e1”，点击“应用当前角色音色”。同名包前有不同短 ID；损坏项不能应用，但未绑定时可删除。
4. 主动启用语音后点击试听，或朗读最近回复。导入和绑定本身不会开启声音。首次启动需要等待，本机测得约 9 秒；连续生成可复用已加载模型。

本地单次最多 600 UTF-16，语速沿用原滑块。长篇手动朗读会提示并改用系统音色读全文。正在启动、生成和播放都可停止；停止会释放播放器和 worker，清理临时 WAV。空闲 3 分钟自动释放。隐藏桌宠不影响仍可见的独立聊天窗；关聊天、离页、换角色、安静、睡眠或退出会停止，不补播。

系统中文音色保留为独立设置和失败回退。没有本地引擎、包损坏或资源缺失会显示原因；正常取消与播放后失败不会回退重读。清理失败可重试停止，索引保存失败只重试本地，不重新生成音频。

## 开发机显式准备

App 不会运行 pip、下载模型或启动训练。准备前正常退出目标 App 和引擎，使用 arm64 Python 3.12。在仓库根运行（使用本机已有实验目录，不从网页下载模型）：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/prepare-local-voice.py prepare \
  --experiment .build/local-role-voice-hutao \
  --python /opt/homebrew/opt/python@3.12/bin/python3.12 \
  --settings-path "$HOME/Library/Application Support/YeShunguangPet-macOS/settings.json"

PYTHONDONTWRITEBYTECODE=1 python3 tools/prepare-local-voice.py check \
  --settings-path "$HOME/Library/Application Support/YeShunguangPet-macOS/settings.json"
```

每次在最终 UUID 路径创建新 venv，校验、安装及导入探针成功后才更新 current.json；不要复制或搬移已有 venv。失败保留旧 current 和现场，可能留下未启用版本目录，先保留日志再排查。环境/模型与代码分开备份，见[模型存放](local-voice-storage.md)。离线推理不会自动补齐缺失语言数据；首版主要支持中文。

语音包只收来自可信来源的 voice.json、s2.pth 和 3–10 秒 32 kHz 单声道 16位 reference.wav。不要自行把大模型放进 Git、App 或普通 Release。后续换角色需要对应模型/参考音频、合规素材和质量验证，不是只改名字。已有 e2、原始录音和实验备份继续保留。
