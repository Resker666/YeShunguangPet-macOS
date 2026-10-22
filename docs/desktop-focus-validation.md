# 0.1.16 桌面计时小窗

日期2026-10-22（Asia/Shanghai），基线8ef5665，分支codex/macos-desktop-focus。用户指出计时应常驻桌面便于查看，选择独立可拖动小窗，批准会话内有界短设计后明确“开始执行”。沿用独立Mac仓库原地实施，不另建工作树；本版只做本地提交与App交付，未授权push/tag/Release。

## 已批准范围

独立小窗默认显示并置顶，记住位置和显示偏好。大号倒计时、状态、开始/暂停/继续、重置；完成停留并手动进入下一段，时长仍在设置调整。关闭小窗只隐藏，计时继续；隐藏角色或关闭设置不影响小窗，双专注菜单可显示和召回。点击、拖动以不打断其他应用输入为目标，实际焦点行为需另行观察。

窗口复用同一个FocusController及原生一次性调度器，可见时登记显示消费者、最多1Hz；隐藏移除自己的消费者，其他计时界面也关闭后只保留截止调度。不会因小窗常驻设置session.settingsOpen，不长期阻挡角色行为或完成回应。只在顶部拖动结束时保存位置，屏幕变化校正边界，不逐帧或逐秒写盘。

采用AppKit非激活NSPanel，系统字体、颜色与按钮；小窗直接订阅发布的快照，不覆盖既有菜单回调。操作绑定原命令和代次，旧暂停不能越过到期边界启动下一段。退出取消显示消费者，取消退出按实际可见性恢复，销毁取消订阅及通知。

schema11新增preferences.focusWindow，包含isVisible、alwaysOnTop及可选placement。专用schema10解码保留旧全部偏好及几何，新迁移默认true/true/nil；1–9继续迁移。当前配置缺字段、非法类型和无效几何保护原字节。普通setPreferences不可绕过专用窗口提交。

显示、置顶和拖动是可逆窗口操作：保存失败仍允许本次临时操作，但不改变已生效的持久偏好；小窗与菜单提供未保存提示/重试，重开可能恢复上次成功保存的偏好。原配置保持不变。此处理避免坏配置让用户无法隐藏小窗；不假称写入成功。

## 阶段验证

- 基线270项原生及13项离线发版已在此前同一8ef5665推送前运行并通过，产品代码未变化，不重复创建基线构建。
- settings-red.log先复现schema10未迁移至11、窗口字段缺失及新版本拒读；随后123项Core通过，core-green.log。旧迁移测试仅更新写出版本，旧坏配置仍用对应版本测试。
- window-api-red.log记录新窗口类型缺失的编译RED。首次工程登记漏加Mac测试目标，修正登记后原生断言实际运行；缺API编译不混称产品行为断言。
- window-runtime-red.log中12项运行、5处断言失败，发现新快照通知时重读旧存储，数字与按钮滞后。publisher-order.log本机最小实例确认published=50时stored=60；改为渲染通知携带的快照，window-green.log十二项全部通过。
- 定向覆盖角色隐藏独立显示、关闭后继续与重新显示、完成及旧按钮、拖动只保存一次与位置独立、召回不显示角色、置顶/显示持久化、写失败及重试、移除屏幕修正、模态/退出、菜单观察兼容、销毁释放、双菜单入口与启动读取隐藏偏好。

以上为阶段证据；最终结果如下。原始日志与本轮执行记录在忽略目录.build/desktop-focus-validation。

## 独立评审与修复

单次全分支、干净上下文、只读评审范围8ef5665..fadeb09，结论With fixes：0项Critical、2项Important、0项Minor。执行者核实并进行一次修复，未进行或宣称独立二次评审。

| 发现 | 核实与处理 | 证据及取舍 |
| --- | --- | --- |
| 系统拖动调用返回后立即保存了拖动前位置 | 本机AppKit NSWindow.h与[Apple文档](https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:))说明该方法立即返回；标题区实际按下/拖动/松开回调测试复现提前写盘及错误坐标。改为原生标题区手势显式更新位置，松开时夹取并保存一次，退出/销毁取消手势 | review-red.log中相关断言失败；修复后通过。无新增全局鼠标监听或拖动轮询，不把测试手动调用finishDrag当作真实标题区事件通过 |
| 原生设置sheet期间完成后，按钮可能一直置灰 | 原生NSWindow sheet回归复现，结束sheet后等待仍置灰、正常performClick无法开始休息。设置窗口sheet结束及filePanel状态变化通过既有owner刷新控件 | review-red.log先失败；修复后原生按钮可正常开始下一段。不增加常驻轮询或等待下次倒计时Tick |

review-red.log的14项中7处期望断言失败，review-green.log十四项通过；另补标题区单击不写盘、退出取消后旧拖动手势不恢复。修复提交为45ae3b3e3f59a91a958f2f7cc83027200b1f0779，完整**289项原生（123Core/166Mac）通过**，含最终16项窗口回归，native-final.log。13项离线发版回归通过，release-tests.log。先期fadeb09的构建、图片和运行证据单独保存在review-initial，不作为修复后交付依据。

## 最终原生探针与界面

修复后Mac源码与对应干净构建的PetCore组成隔离ad-hoc Bundle，使用临时配置和素材；不写个人配置、不改正式登录项、无网络请求。

- 已逐图检查浅色/深色准备、运行、暂停、完成、休息、保存失败及真实分钟完成共8张原生控件渲染，280×208窗口中数字、状态和按钮完整可读。
- 控制器与原生按钮分派验证暂停/继续、旧按钮不能跨完成边界开始下一段、手动休息、关闭只隐藏、召回不显示角色、失败磁盘保留及重试。最终探针通过标题区原生鼠标回调序列验证230/220最终坐标持久化；这些仍是程序化事件，不记为真实鼠标操作。
- 隐藏角色、显示小窗，以真实连续时钟运行一分钟，实际耗时**60.056秒**，采集到**60个不同秒数**，完成一次后保持专注完成及00:00、不自动进入休息；窗口仍可见、角色仍隐藏、完成后无挂起调度。FocusController调度器唤醒60次；探针为等待结果另外做了574次100ms检查，不宣称全进程仅60次唤醒。
- native-probe.json/.log、probe.swift及timer-*.png保留原始结果。尝试读取隔离小窗的原生界面自动化时，工具在请求20秒超时参数下实际610秒后返回-10005 timeoutReached；没有取得界面操作结果。此失败记录在ui-automation.json，不作为真实拖动或跨应用焦点通过。

## 最终安装包与日用App

从干净45ae3b3e3f59a91a958f2f7cc83027200b1f0779导出构建，trackedChanges=false，版本0.1.16/build17；后续仅文档提交，App来源仍固定此提交。

- 修复后导出工程的10项分发测试通过，distribution.log；包括schema1→11及新偏好独立进程重开、素材缺失回退等原回归。双架构App与DMG/ZIP各自库存、符号链接、签名、最低macOS15、动态依赖、原素材和SHA-256核对通过。
- 八份版本化安装/校验文件的prepare-release.py --check-only通过，完全离线，未创建草稿、标签或Release。
- ARM从DMG复制到含中文/空格路径，弹出DMG后从/private/tmp、剥离开发变量且DEVELOPER_DIR无效的环境正常启动、退出并重开恢复；只证明本机搬移，不证明外机或Gatekeeper首开。
- 按准确路径正常退出旧0.1.15，备份旧App及退出后的个人配置，更新/Applications/YeShunguangPet.app为0.1.16。schema10→11迁移后，原偏好、所选皮肤、更新时位置（小于1点取整差）、快捷键、时长与个人台词均保留，窗口新增true/true/nil。移除验证环境变量后重新启动，保持运行，未登记或撤销正式登录项。
- 另按已安装App进程PID过滤系统在屏窗口几何，确认新的280×208计时器实际显示，installed-window.json；未读取其他应用内容，也不据此推断其他应用焦点。

App：/Applications/YeShunguangPet.app。安装包：dist/YeShunguangPet-0.1.16-macOS-arm64.dmg；Intel实验包另标x86_64。完整证据在.build/desktop-focus-validation，包括final-source.json、review-summary.json、package-verification.json、final-relocated-smoke.json、release-assets-check.json、final-delivery.json、local-install.json及旧App/配置备份。个人备份不提交或上传。

保持本地分支codex/macos-desktop-focus，未合并main、推送、打标签、建草稿或发布。真实键鼠/跨应用焦点、系统睡眠/Spaces/登录/多屏热插拔、Intel/黑苹果、外机/Gatekeeper与本机整体体验仍待用户按实际结果确认；项目待办已保留。

## 用户验收及推送授权

用户随后在本会话反馈“验证通过，推送，下一版做什么”，确认0.1.16独立桌面计时窗版本的本机整体体验，授权按既有流程同步main和codex/macos-desktop-focus。只做普通push，不触发prepare_release，不创建标签、Release草稿或公开发布。

该反馈不扩展为全部拖动、置顶、隐藏/召回、计时各状态、失败/取消/重开或跨应用焦点均逐项实测；系统、Intel/外机/Gatekeeper继续按实际证据记录。已超时的界面自动化不改写为通过。此前“待体验”和“未推送”为本地交付时状态，后续远端及CI结果另行核对；下一版尚未获产品实施授权。
