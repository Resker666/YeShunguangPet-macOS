# 午夜日期通知崩溃修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复D资源测量期间真实发生的午夜崩溃，保留资源基线并本地交付0.1.21/build22。

**Architecture:** Foundation日期、时钟和时区通知进入非隔离selector，在主线程保留同步刷新，在后台投递时转至MainActor后刷新。退出/销毁后的排队工作忽略；不修改统计归属、计时规则、schema13或调度频率。

**Tech Stack:** Swift6、AppKit、XCTest，macOS14+，无外部依赖。

**Spec:** [D调查与真实崩溃证据](../../resource-baseline-validation.md)，本地`crash-summary.json`中00:00的两份SIGTRAP堆栈。

## Global Constraints

- 原地独立Mac仓库，本会话直接实施；只本地提交，不推送、打标签或发布。
- Windows与Minimal Sleep只读；个人配置、皮肤、位置、快捷键和统计保留，正式登录项不改。
- 原四组各600秒与2520秒日用参考有效；额外305.92秒复测在崩溃时中断，不能混作完整组或新版本基线。
- Swift6、最低macOS14.0，arm64日用；x86_64只做交叉构建，真实系统专项分别记录。

## Review Focus

- 日期/时钟/时区三种后台通知均须实际刷新今日统计和菜单，且回调在主线程。
- 主线程通知继续同步刷新，现有统计与时区回归不能退化。
- 已排队通知遇到dispose后不得刷新、写盘或重新安排计时器。
- 跨日只更新当前投影，不重归属或清除已保存汇总。
- 资源报告区分旧版数据、显示条件、部分样本与修复验证；不能宣称跨过下一次真实午夜已验证。

## Task 1：修复并交付

**Files:** 修改`Sources/YeShunguangPet/FocusController.swift`、`Sources/YeShunguangPet/Info.plist`、`Tests/PetMacTests/FocusPresetStatisticsTests.swift`；更新`docs/resource-baseline-validation.md`、README、TODO与AGENTS。

**Interfaces:** 保留三类通知注册和`refreshStatistics()`、`onChange`；非隔离selector只决定执行上下文，主Actor处理器负责disposed门控和现有刷新。

- [x] 在既有fixture补后台投递三类通知的回归：旧日完成1段，转到次日，等待通知后断言今日0次、菜单0次、保存旧日1次、无额外写盘/计时器且onChange在主线程；先运行观察旧实现SIGTRAP。
- [x] 最小修复通知入口；补排队后dispose的回归，保留主线程同步测试；运行完整`bash scripts/test.sh`与13项离线发版回归。
- [x] 记录单一最终评审座位的代码和报告核对；修复其有效发现后提交，干净来源构建双架构App与包，完成13项分发和八附件来源校验。
- [x] 独立临时配置的原生程序重复后台投递通知并核对结果；备份/正常退出日用App，安装ARM版本，核对个人状态与自身窗口并保留旧App；更新真实结果与未测项，本地提交。

自审：本补丁仅修复已证实的Foundation通知线程入口；现有AppKit/NSWorkspace通知没有相同故障证据，保持原实现。测量数据与修复后App来源分开，不用旧版资源数据宣称新版性能改善。
