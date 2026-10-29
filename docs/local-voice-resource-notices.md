# 本地语音资源来源说明

整理日期：2026-10-29。公共引擎1.0.0与胡桃试用e1分别打包；程序源码、本地运行时、公共模型和角色素材采用各自来源声明，不能统一视作本项目MIT资产。

公共引擎采用固定GPT-SoVITS源码提交b4570b876f5c086819ba84e3215472733c6a7b70、Python3.12.14及106项固定依赖；完整许可证与RUNTIME_PROVENANCE.json保留在引擎payload/licenses内。引擎不含胡桃S2权重或参考原声。重新压缩只改变DMG容器，原清单和全部payload字节保持。

- GPT-SoVITS源码及其所带BigVGAN等子项保留原许可证：https://github.com/RVC-Boss/GPT-SoVITS 。
- S1v3官方文件页标MIT，其SHA256 87133414860ea14ff6620c483a3db5ed07b44be42e2c3fcdad65523a729a745a与当前引擎字节相同：https://huggingface.co/lj1995/GPT-SoVITS/blob/main/s1v3.ckpt 。固定来源修订的README历史快照未另取得。
- 中文RoBERTa原模型卡标Apache-2.0：https://huggingface.co/hfl/chinese-roberta-wwm-ext-large ；中文HuBERT原模型卡标MIT：https://huggingface.co/TencentGameMate/chinese-hubert-base 。当前文件取自固定GPT-SoVITS镜像，未逐字节比对两者原仓库。
- ERes2NetV2来自该固定镜像；3D-Speaker源码有Apache-2.0声明，但当前checkpoint专属声明仍未取得，不能以源码许可替代：https://modelscope.cn/models/iic/speech_eres2netv2w24s4ep4_sv_zh-cn_16k-common 。
- G2PW作者checkpoint模型卡有Apache-2.0声明：https://huggingface.co/YC-Chen/g2pW/commit/fb4784f7dce8466a53dd4f3552f5a4c5b657b90c 。当前镜像ZIP与作者ZIP压缩包SHA不同，内部checkpoint对应关系尚未核实；原仓库：https://github.com/GitYCC/g2pW 。
- fastText lid.176.bin原模型声明CC BY-SA 3.0，保留原字节/出处：https://fasttext.cc/docs/en/language-identification.html 。有关Python包的MIT代码许可不替代模型声明。

胡桃包为现有S2微调e1，原模型172,756,275字节、参考WAV625,316字节。素材由使用者手动提供的39条中文游戏原声中选择14条、约69.2秒用于试验，来源页面：https://genshin-impact.fandom.com/wiki/Hu_Tao/Voice-Overs/Chinese 。包内参考录音是运行必需输入；其他原始录音、训练资料和实验环境未收入ZIP。

胡桃角色、原声、音色及相关素材不属于本项目MIT源码。现有记录未包含明确的公开再分发声明，旧实验清单标localOnly；本次整理不把这些事实改写成已取得公开许可。ERes checkpoint、G2PW内部对应关系与胡桃素材分发依据仍是未核实项，应随本包及其来源记录保留。

此包只记录当前试验版本，试听接近程度是少量句子的反馈，不保证完整复刻、任意文本或其他语言质量。当前真实设备覆盖M4；macOS14、其他M系列、外机Gatekeeper仍未实测，Intel不支持此本地引擎。
