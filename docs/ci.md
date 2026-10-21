# macOS 云端构建

用户于2026-10-21批准本会话实施GitHub Actions：复用现有脚本，在云端构建ARM/Intel安装包，上传到每次运行的Artifacts，保留14天。继续使用独立Mac仓库，不新增工作树；只读参考Minimal Sleep的Actions编排，未改动其仓库。

## 触发和环境

- 推送到`main`或`codex/**`分支。
- PR的目标分支为`main`，构建GitHub默认的PR合并提交。
- 手动`workflow_dispatch`；工作流进入默认分支后，在仓库Actions中选择`macOS App → Run workflow`，再选择分支。

工作流文件为`.github/workflows/macos-build.yml`，使用标准`macos-26` Apple Silicon runner，明确选择`/Applications/Xcode_26.6.app/Contents/Developer`。GitHub官方镜像清单在实施时列出此版本；若镜像以后移除该路径，应先核对官方清单再更新，不能静默换成另一工具链。运行日志记录macOS、架构、Xcode、Swift、Python与完整构建提交。

Token只申请`contents: read`，checkout不持久化凭据；不需要个人PAT、SSH私钥、Apple开发者证书或公证凭据。没有自动提交、推送、打标签、发布或修改应用个人设置的步骤。同一分支的新运行取消仍在执行的旧运行，单次任务上限30分钟。`main`和开发分支同时推送会各触发一次运行。

## 验证与安装包

步骤依次执行，任一检查失败就停止后续安装包上传，不用`continue-on-error`掩盖失败：

1. `bash scripts/test.sh -resultBundlePath .build/ci-logs/native-tests.xcresult`。
2. `bash scripts/build-app.sh arm64`及`bash scripts/build-app.sh x86_64`，执行Release构建及ad-hoc签名。
3. `python3 -m unittest discover -s Tests/Distribution -v`，在ARM runner上检查打包、架构拒绝、素材/签名、中文路径搬移与独立ARM进程重开等已有回归。
4. `bash scripts/package-app.sh arm64`及`bash scripts/package-app.sh x86_64`，生成两套DMG/ZIP和校验文件。
5. 再检查两份App的`build-info.json`对应本次完整提交、`trackedChanges=false`、架构正确，源码无已跟踪修改，并检查全部8个安装/校验文件存在及SHA-256通过。

`shell: bash`使用GitHub提供的`-e -o pipefail`执行方式，保留`tee`日志的同时传递真实命令失败状态。分发测试会在隔离目录修改测试副本，不覆盖正式App；独立进程测试隔离配置与Skins，不读写日用配置。

上传分为以下产物，名称中的运行编号和重试次数避免同次重跑名称冲突：

| 产物 | 内容 |
| --- | --- |
| `YeShunguangPet-<版本>-arm64-<运行编号>-<重试次数>` | M系列DMG、ZIP、对应的两个`.sha256` |
| `YeShunguangPet-<版本>-x86_64-<运行编号>-<重试次数>` | Intel实验DMG、ZIP、对应的两个`.sha256` |
| `macOS-diagnostics-<运行编号>-<重试次数>` | 环境和各阶段日志；已运行测试的`native-tests.xcresult` |

全部保留14天。成功安装包只选取`dist`根目录相应架构的4个文件，不直接上传`.app`或整个工作区。DMG和内层ZIP由原打包脚本保存App执行权限、框架符号链接、安装说明、素材和许可。诊断上传使用`always()`，仅包含`.build/ci-logs/`；若checkout或环境阶段已失败到无法生成日志，可能没有诊断文件。取消、超时或GitHub服务异常时也不能保证诊断上传成功。

## 下载和排错

登录GitHub，进入仓库`Actions → macOS App → 一次成功运行`。在摘要点对应架构链接，或在页面底部`Artifacts`下载；先解压GitHub外层ZIP，再使用其中的DMG或备用ZIP。核对该次提交与运行状态，避免将旧运行产物当作最新版。

若需要核对完整性，在解压后的同一目录执行：

```bash
shasum -a 256 -c YeShunguangPet-0.1.8-macOS-arm64.dmg.sha256
```

版本或架构不同则替换对应文件名。`.sha256`检查文件完整性，不替代可信开发者身份。安装包内`Contents/Resources/build-info.json`可回查构建提交；PR产物对应合并测试提交，不能当作已合并主干的正式版本。

失败时先看失败步骤日志，再下载诊断产物；`native-tests.xcresult`可在Xcode打开。若只有诊断产物，没有安装产物，说明本次未完成全部检查。工作流仅将通过全部检查的包上传为安装产物，不自动发布Release。

## 验证边界与来源

本机排练成功不能写成GitHub云端成功。云端运行需用户明确授权推送工作流后再验证；目前不把尚未发生的云端构建、上传或下载写成已通过。云端Xcode 26.6与本机Xcode 27不同，首次运行可能暴露编译器、SDK、WindowServer或测试时限差异，应根据真实失败修复。

云端即使全部通过，也只证明对应机器上的构建与自动回归。Intel为ARM机器上的交叉构建，不证明Intel／黑苹果运行；ARM独立进程验证不证明其他系统、用户鼠标、Spaces、真实睡眠或网上下载后的Gatekeeper首开。产物仍为ad-hoc签名、未公证，安装时沿用README与安装说明中的系统操作。

实施时核对的官方资料：

- [GitHub标准runner及架构](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。
- [macOS 26 ARM镜像与Xcode清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)。
- [上传产物、保留期限及权限说明](https://github.com/actions/upload-artifact)。
- [手动运行工作流](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)。
