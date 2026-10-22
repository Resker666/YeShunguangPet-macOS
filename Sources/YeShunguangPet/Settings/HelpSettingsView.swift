import SwiftUI

struct HelpSettingsView:View {
    @ObservedObject var diagnostics:SupportDiagnosticsModel
    var body:some View {
        Form {
            Section("反馈问题") {DiagnosticCopyControls(model:diagnostics)}
            Section("找到角色与退出") {
                Text("App 不显示 Dock 图标。点击菜单栏爪印可显示、隐藏或召回角色；召回会把角色带回屏幕内。完全退出请使用爪印菜单的“退出”。")
            }
            Section("移动与互动") {
                Text("拖动角色移动，松开后保存位置。单击挥手，双击跳跃；皮肤缺少动作时按可用动作回退。右键角色也可打开常用操作。")
                Text("“锁定位置”暂停拖动和自动走动，保留点击和召回。“安静模式”暂停主动互动与提示音，本次退出后恢复正常。")
            }
            Section("换肤与设置") {
                Text("在“皮肤”页选择一套皮肤的 ZIP、文件夹或 pet.json，预览后确认导入。也可拖到设置窗口；菜单栏“切换皮肤”可使用已导入的角色。")
                Text("“通用”页调整缩放、置顶和位置选项；“互动”页控制注视、自动动作、走动和台词。登录启动与快捷键需你按需开启。")
            }
            Section("专注计时窗") {
                Text("从“专注计时”菜单显示独立计时窗。隐藏桌宠后仍可计时；小窗可拖动并切换紧凑模式，关闭只隐藏。每段结束后手动开始休息或下一次专注。")
                Text("今日统计只累计完整完成段的计划分钟，不计未完成段或休息。退出结束当前段，保留已保存的统计。")
            }
            Section("安装与常见排查") {
                Text("macOS 14 或更新系统：M 系列选择 arm64 包，Intel 选择 x86_64 包。把 App 复制到“应用程序”，弹出 DMG 后再打开；使用 App 不需要 Xcode。")
                Text("体验包未公证。首次打开被系统拦截时，先核实来源，再按系统“隐私与安全性”中的提示允许；若提示损坏，先重新下载并保留原始报错。")
                Text("位置失效先用“召回角色”；无法拖动先检查“锁定位置”。设置保存失败可从菜单栏重试，原配置受保护时先备份再重置。")
                Link("查看官方发布页",destination:URL(string:"https://github.com/Resker666/YeShunguangPet-macOS/releases/latest")!)
            }
        }.formStyle(.grouped).textSelection(.enabled)
    }
}

struct DiagnosticCopyControls:View {
    @ObservedObject var model:SupportDiagnosticsModel
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Button("复制诊断信息"){model.copyDiagnostics()}
            Text("点击时生成版本、系统架构、窗口位置和配置状态摘要。不会复制私人路径、个人台词、完整配置或原始错误，也不会上传。").font(.caption).foregroundStyle(.secondary)
            if let message=model.feedback.message {Text(message).font(.caption).foregroundStyle(model.feedback == .copied ? Color.secondary : Color.red)}
        }
    }
}
