# 0.1.19 macOS 14兼容记录

日期：2026-10-22（Asia/Shanghai）。用户确认按前述范围修改，继续独立Mac仓库原地开发；本轮仅本地交付，未授权推送、标签或Release。

## 原因与范围

用户黑苹果截图显示macOS Sonoma 14.8.9、2.11 GHz四核Intel Core i5、16 GB内存。0.1.11 x86_64打开时提示系统版本不兼容；检查该版及本地0.1.18均声明最低15.0，当前App和PetCore的Mach-O也实际要求15.0。截图中的机型识别不作为真实硬件型号，不记录序列号。

0.1.19/build20将App、PetCore及测试目标的Debug/Release共八处部署目标和App声明统一为14.0，不改变运行行为、原素材或schema13。打包校验器核对架构、macOS平台及两个Mach-O的实际最低系统版本，继续检查签名、系统依赖和原素材。安装说明、README及黑苹果待办同步更新。

## 证据与限制

- 本地SDK27.0支持macOS14.0部署及x86_64；只读API核验未发现必须15+的调用。双参数SwiftUI onChange要求14.0，SMAppService与ContinuousClock要求13.0。该检查不代替编译和运行。
- 新增分发回归先复现：签名有效的主程序或框架改为要求macOS16，旧校验器仍接受；现有ARM/Intel包也不满足14.0要求。三项测试产生四处预期断言失败，记录于忽略目录`.build/sonoma-compatibility-validation/deployment-red.log`。
- 最终编译、回归、评审、打包和个人App更新结果在完成后追加；此处不预先记为通过。
- Sonoma14.8.9、Intel／黑苹果实际启动、真实鼠标/焦点、睡眠/Spaces、多屏、重新登录及下载后Gatekeeper首开仍待实机验证。本机M4运行或交叉构建不能覆盖这些结果。

黑苹果手动验收见[步骤](intel-validation.md#黑苹果验收)。本轮未改Windows、Minimal Sleep或正式登录项。
