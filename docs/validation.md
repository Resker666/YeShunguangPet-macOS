# 本地验证记录

日期：2026-10-20，Asia/Shanghai。目标：首个本地开发预览版；用户已体验并确认下述基本交互正常。Windows 版测试不计入 Mac 结果。

## 环境与构建来源

- Mac mini M4、16 GB、arm64；macOS 27.0（26A428）。
- Xcode 27.0（27A266a）、Swift 6.4、macOS SDK 27.0。
- macOS 部署目标 15.0；仅在实际 27.0 环境验证。
- 源码提交与最终包来源分别记录在 Git 历史和 App 的 `Contents/Resources/build-info.json`。
- `.build/` 保存本机日志与采样数据，未加入 Git；dist/ 保存本机产物，不公开上传。

## 已执行

| 检查 | 真实结果与范围 |
| --- | --- |
| XCTest | 30 个 core + 10 个 AppKit 测试，共 40 个，0 失败；TEST SUCCEEDED，退出0 |
| Release 构建 | xcodebuild 显示 BUILD SUCCEEDED，退出 0 |
| 真实叶瞬光加载与裁帧 | 原 JSON/PNG 哈希一致；1536×2288；裁帧192×208；方向夹具验证上下、列与 alpha |
| 帧时钟 | 不等长帧、精确边界、循环、单次结束、长延迟、暂停恢复通过 |
| 输入与生命周期 | 单/双击/拖动互斥、取消待判定点击、隐藏后睡眠/唤醒不恢复调度通过自动化 |
| 位置与配置 | 重开恢复、负坐标、显示区域变化、屏幕移除、越界限制、损坏文件保护、写入失败通过隔离测试 |
| 原生绘制与菜单 | 自建 NSPanel/View 实际绘制方向与透明；菜单文案、错误禁用状态、调度取消通过 |
| 独立 App 启动与退出 | smoke-app.py 等待运行就绪（最多15秒），随后保持运行2秒；SIGTERM 走正常退出路径，退出0、配置与指标落到临时目录 |
| 签名和资源 | 本地 ad-hoc codesign 验证通过；资源原哈希保持一致 |
| 打包 | 最终修复包ditto ZIP；SHA-256校验通过；解包后的程序、框架、真实资源和构建来源一致，解包后签名验证通过 |
| 用户实机体验 | 用户明确反馈“已体验，以上操作正常”：拖动、单击/双击、菜单隐藏/显示和召回；这是用户反馈，不是自动化鼠标验证 |

## 明确未验证

菜单栏点击退出、其他应用持续输入时的焦点、Spaces、全屏应用、Stage Manager、物理外屏拔插、锁屏与真实睡眠唤醒未实测。界面工具 `cua.getApp` 首次超时约20分钟，后续以 App 完整路径重试可读取窗口和实际角色画面；自动拖动未得到位置保存证据，因此基本输入采用用户反馈。没有将窗口属性或模拟通知写作系统场景通过。

AppKit 测试通过与独立进程可运行支持交付本地体验，但不能替代用户实际体验。透明区域穿透、长时日用稳定、耗电和其他 macOS 版本未测。

## 遇到并修复的失败

1. Xcode 在受限沙箱内向系统发送测试进度通知时崩溃；本机 XCTest 运行可执行。未把该环境错误算作测试 RED。
2. 首次独立 App 启动因 PetCore 使用 `/Library/Frameworks` 绝对 install name 而 dyld 早退 -6。XCTest 的框架搜索路径掩盖此问题；增加真实包启动回归，将 install name 改为 `@rpath/PetCore.framework/Versions/A/PetCore` 后验证启动正常。
3. 初始 SIGTERM 直接终止 -15，不执行保存；以 DispatchSourceSignal 转到 NSApplication 正常终止。后续发现固定2秒的冷启动假设不可靠，改为等待运行就绪后再测；隔离配置与运行指标写入、退出0通过。
4. 本机 ps comm 即使用 -ww 仍将可执行路径截为15字节，首次性能采样因此拒绝PID并未开始；改用 libproc.proc_pidpath 核验完整路径，重新采集的600秒样本完整完成。
5. Xcode 输出 AppIntents 无依赖的元数据跳过警告，AppKit 测试 runner 输出 StatusBar/系统连接诊断；用例和构建没有因此失败。坏 PNG 拒绝用例会产生 ImageIO 预期解码错误日志。
6. 最终独立评审复现：ImageIO 接受仅剩1/8、1/4、1/2图像数据，以及缺失IEND的真实PNG。新增数据块边界、CRC和结束块校验；校验依据为 [W3C PNG结构规范](https://www.w3.org/TR/png-3/#5DataRep)。仍由ImageIO解码像素，不自行实现图像解码器。截断与CRC损坏两项回归在旧代码上断言失败，修复后通过。
7. 最终独立评审复现：拖动被取消后仍保持runningRight，并跳过位置保存。取消现在报告是否中断拖动，会完成位置限制/保存并回到idle，不产生点击。菜单取消、隐藏/显示、模拟睡眠/唤醒和显示变化四种路径的回归在旧代码上失败，修复后通过；这些通知测试不等于真实系统睡眠验证。

最终评审范围为`6b555cc..494dfc2`，无Critical、两项Important、无Minor、无搁置判断。两项Important均按上述失败回归修复；全套40测试通过。评审未重跑全套测试，执行者保存了真实RED与GREEN日志：`.build/validation/review-red.log`、`review-green-full-tests.log`。决策与代价见 [执行取舍](development-decisions.md)。

## 命令

```bash
bash scripts/test.sh
bash scripts/build-app.sh
python3 scripts/smoke-app.py
bash scripts/package-app.sh
# 仅对本次自行启动的独立 App PID：
python3 tools/sample_process.py --pid PID --duration 600 --interval 5 --output .build/performance-run/process.json
```

## 十分钟可见 idle 基线

采样源码提交：`605632da2d266e920f047207ceafff5fa8240612`；单角色可见 idle，192×208逻辑点。实际屏幕可用区域1920×972逻辑点，backingScale=1。采样期间同时进行文档工作及一次角色画面读取，没有压力测试。完整原始数据在 `.build/performance-run/{process,metrics}.json`。

| 指标 | 实际结果 |
| --- | --- |
| 进程采样时长 | 600.013秒；121个样本；completed=true |
| 单核归一化平均CPU | 0.9116%（进程CPU时间差/单调墙钟差×100） |
| RSS | 82.484–90.297 MiB |
| 会话指标时长 | 600.122秒 |
| 调度唤醒 / 绘帧 | 3272 / 3315 |
| 退出 | SIGTERM经正常终止回调退出0，配置和指标保存 |

RSS包含共享页，不等于独占内存；本数据不是耗电、过夜稳定性或Retina性能结论。最终交付包按最终提交另行构建，不能把此样本声称为尚未构建的提交实测。
