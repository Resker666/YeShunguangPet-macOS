# 公共语音模型来源与许可记录

本记录随本地引擎分开提供，不把公共模型、Python、第三方代码或角色素材改称本项目 MIT 源码。角色 S2 权重和原声不包含在公共引擎中。2026-10-29用户已批准建设GitHub资源分发工具，具体资源公开仍待最终文件/正文和明确指令；下列“声明”是来源证据，不代表已核实每份 checkpoint 的再分发许可。新整理的外层[来源说明](local-voice-resource-notices.md)补充证据，不改既有引擎payload字节。

- GPT-SoVITS 源码：RVC-Boss，固定提交 `b4570b876f5c086819ba84e3215472733c6a7b70`，保留原 MIT LICENSE、BigVGAN 及其 incl_licenses、其他源码内许可。
- S1v3：镜像 `lj1995/GPT-SoVITS`，固定资源来源修订 `8f8857563c040d542de108a2c18b0425abd6c9c5`。[官方文件页](https://huggingface.co/lj1995/GPT-SoVITS/blob/main/s1v3.ckpt)标MIT，SHA256 `87133414860ea14ff6620c483a3db5ed07b44be42e2c3fcdad65523a729a745a`与当前文件相同；[当前模型卡](https://huggingface.co/lj1995/GPT-SoVITS/blob/main/README.md)亦声明MIT。固定修订的模型卡历史快照未另取得。
- 中文 RoBERTa：HFL，[官方模型卡](https://huggingface.co/hfl/chinese-roberta-wwm-ext-large)声明 Apache-2.0，[许可证](https://github.com/ymcui/Chinese-BERT-wwm/blob/master/LICENSE)。当前字节取自上述固定 GPT-SoVITS 镜像，未与 HFL 原仓库逐字节比对。
- 中文 HuBERT：TencentGameMate，[官方模型卡](https://huggingface.co/TencentGameMate/chinese-hubert-base)声明 MIT，[来源](https://github.com/TencentGameMate/chinese_speech_pretrain)。当前字节取自固定镜像，未与原仓库逐字节比对。
- ERes2NetV2 说话人 checkpoint：来自固定镜像；对应[ModelScope 页面](https://modelscope.cn/models/iic/speech_eres2netv2w24s4ep4_sv_zh-cn_16k-common)的 checkpoint 专属许可未核实。相关 [3D-Speaker 源码许可](https://github.com/modelscope/3D-Speaker/blob/main/LICENSE)及原代码头为 Apache-2.0，不能据此替代 checkpoint 许可。
- G2PW v2.0：资源镜像 `XXXXRT/GPT-SoVITS-Pretrained`，固定修订 `38667825262269462109e123fff3ecfb8d3b9d88` 的 G2PWModel.zip；[当前镜像模型卡](https://huggingface.co/XXXXRT/GPT-SoVITS-Pretrained/blob/main/README.md)标 MIT。[原 g2pW 项目](https://github.com/GitYCC/g2pW)及其[LICENCE](https://github.com/GitYCC/g2pW/blob/master/LICENCE)为 Apache-2.0；保留两者证据，具体 checkpoint 对应关系仍未核实。
- 2026-10-29补充：原g2pW仓库链接的[作者checkpoint模型卡](https://huggingface.co/YC-Chen/g2pW/commit/fb4784f7dce8466a53dd4f3552f5a4c5b657b90c)标Apache-2.0并提供归档SHA。当前镜像ZIP与作者ZIP摘要不同，尚未比较内部checkpoint，不能仅据不同压缩包判断模型不同或一致。
- fastText `lid.176.bin`：Facebook Research，[官方原文件](https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.bin)；[官方语言识别说明](https://fasttext.cc/docs/en/language-identification.html)明确模型采用 [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/)。本包保留模型原字节和出处；`fast_langdetect`/`fasttext_predict` 包的 MIT **代码**许可不能替代模型的 CC BY-SA 声明。

Python 的发行档案、全部推理依赖及本地源码构建的版本/摘要见引擎内 `RUNTIME_PROVENANCE.json`；运行时和源码中已有的许可文件保留原字节，并在本目录另汇集一份。公开分发模型前应另核实上述未确定的权利，不能把本地可运行或摘要校验当作公开分发许可。
