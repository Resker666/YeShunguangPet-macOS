# 0.1.2 双架构分发与Intel实验包

日期：2026-10-20（Asia/Shanghai）。用户希望继续推进跨机器分发，并提供黑苹果作为后续测试机；CPU型号与系统版本尚未提供。

本次在现有打包流程中增加可选的x86_64交叉构建。arm64仍为M4日用默认；两个架构单独出包，不制作Universal包，不修改桌宠运行逻辑。部署目标仍为macOS 15.0，版本0.1.2 / build 3。

## 构建与产物

```bash
bash scripts/build-app.sh              # ARM，原路径dist/YeShunguangPet.app
bash scripts/build-app.sh x86_64       # Intel，独立路径dist/x86_64/YeShunguangPet.app
bash scripts/package-app.sh            # DMG/ZIP名称含arm64
bash scripts/package-app.sh x86_64     # DMG/ZIP名称含x86_64
python3 -m unittest discover -s Tests/Distribution -v
bash scripts/test.sh                   # 当前M4上的40项原生XCTest
```

两套DMG/ZIP及校验和均保存在dist根目录，例如`YeShunguangPet-0.1.2-macOS-x86_64.dmg`。安装说明顶部自动标明架构；Intel版明确标记“实验、运行未验证”。版本、源码提交和架构记录在App内`Contents/Resources/build-info.json`。

## 实际证据

| 项目 | 结果与范围 |
| --- | --- |
| 工具链可行性 | 当前M4 / Xcode 27.0 / Swift 6.4成功交叉编译x86_64，BUILD SUCCEEDED；未安装额外工具链或系统组件 |
| 两套App | 主程序和嵌入PetCore分别为arm64或x86_64，架构一致；签名校验通过；依赖限于随包框架和系统路径 |
| 保留ARM产物 | 真实临时工程中运行Intel构建；已有ARM App逐文件内容和链接保持一致。旧脚本忽略架构选择（RED），新脚本通过（GREEN） |
| 架构识别与Intel打包 | 旧校验器拒绝合法Intel App、旧打包脚本忽略x86_64（RED）；修复后正确生成Intel名称的DMG/ZIP，校验和和实际包内容通过（GREEN） |
| 错误架构防护 | 主程序与框架混用ARM/Intel时拒绝；指定arm64而输入Intel App时拒绝，不生成误标签安装包 |
| 分发集成回归 | 全8项通过，含真实交叉构建、两种架构打包、只读挂载和解包、ARM搬移后的两次启动与位置恢复 |
| 原有功能回归 | M4原生XCTest共40项（30 core + 10 AppKit），0失败，TEST SUCCEEDED |
| 资源 | 原JSON/PNG哈希保持不变，图标、安装说明与许可均随包；两种包仍为ad-hoc签名、未公证 |

原始日志保存在`.build/intel-validation/`，含`probe-build.log`、`build-red.log`、`build-green.log`、`package-red.log`、`package-green.log`、`xctest-final.log`和`distribution-final.log`。最终构建与包来源以App内build-info为准。

## 明确未测

本机`/usr/bin/true`包含x86_64切片，但`arch -x86_64 /usr/bin/true`返回Bad CPU type；pkgutil也未找到RosettaUpdateAuto安装记录。本轮没有安装Rosetta，没有执行Intel App或Intel XCTest。因此交叉构建、签名、挂载和解包均不代表Intel／黑苹果运行通过。

黑苹果CPU与系统尚不明确，macOS 15以下不在当前部署目标内；Intel原生Mac、AMD黑苹果、其他macOS版本、浏览器下载后的Gatekeeper首开及未装Xcode外机均未验证。黑苹果的测试结果将按该具体硬件/系统记录，不能直接推广为所有Intel或M系列外机通过。

## 黑苹果验收

先确认CPU型号和macOS版本；可选使用系统自带命令，无需Xcode：

```bash
sysctl -n machdep.cpu.brand_string
sw_vers -productVersion
```

系统满足当前部署目标时：下载x86_64 DMG → 复制到“应用程序” → 弹出DMG → 按系统正常流程首次打开 → 观察动画 → 拖动/单双击 → 菜单隐藏/显示/召回 → 菜单退出 → 重开检查位置。失败时保留完整错误提示、CPU与系统信息。免费包仍可能需要按随包Apple说明手动允许。

本次仅本地提交和打包，不推送、打标签或公开发布。
