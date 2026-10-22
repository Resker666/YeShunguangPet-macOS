import SwiftUI
import PetCore

struct FocusSettingsView:View {
    @ObservedObject var focus:FocusController
    @State private var focusText:String
    @State private var breakText:String
    @State private var error:String?
    init(focus:FocusController) {
        self.focus=focus;_focusText=State(initialValue:String(focus.focusMinutes));_breakText=State(initialValue:String(focus.breakMinutes))
    }
    var body:some View {
        let primaryCommand=focus.primaryCommand
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                VStack(spacing:10) {
                    Text(focus.statusText).font(.title2)
                    Text(focus.timeText).font(.system(size:46,weight:.medium,design:.rounded)).monospacedDigit()
                        .accessibilityIdentifier("pet-focus-remaining")
                    ProgressView(value:1-Double(focus.remainingSeconds)/Double(max(1,focus.snapshot.durationSeconds)))
                    HStack {
                        Button(focus.primaryTitle) {focus.perform(primaryCommand)}
                            .id(primaryCommand).buttonStyle(.borderedProminent).accessibilityIdentifier("pet-focus-primary")
                        Button("重置") {focus.reset();reloadDrafts()}.disabled(focus.status == .ready)
                    }
                }.frame(maxWidth:.infinity).padding().background(.quaternary,in:RoundedRectangle(cornerRadius:12))
                VStack(alignment:.leading,spacing:8) {
                    Text("快捷开始").font(.headline)
                    HStack {
                        ForEach(FocusController.presetMinutes,id:\.self) {minutes in
                            let command=focus.presetCommand(minutes:minutes)
                            Button("\(minutes) 分钟"){focus.startPreset(command)}.id(command)
                        }
                    }.disabled(!focus.canStartPreset)
                    Text("准备状态可用；保存为常用专注时长后开始，休息时长不变。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error=focus.presetError{Text(error).font(.caption).foregroundStyle(.red)}
                }
                VStack(alignment:.leading,spacing:8) {
                    Text("今日专注").font(.headline)
                    Text("完成 \(focus.todayStatistics.completedCount) 次 · 累计 \(focus.todayStatistics.plannedMinutes) 分钟")
                    Text("只统计完整完成的专注段计划时长，包含睡眠；重置或退出未完成段不计，休息不计。按结算时本地日期归属，只保留当天汇总。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error=focus.statisticsSaveError {
                        Text("统计尚未保存：\(error)").font(.caption).foregroundStyle(.orange)
                        Button("重试保存统计"){focus.retryStatisticsSaving()}
                    }
                }.accessibilityIdentifier("pet-focus-today-statistics")
                VStack(alignment:.leading,spacing:10) {
                    Text("时长").font(.headline)
                    HStack {
                        Text("专注");TextField("25",text:$focusText).textFieldStyle(.roundedBorder).frame(width:64).accessibilityLabel("专注分钟")
                        Text("分钟（1–120）").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("休息");TextField("5",text:$breakText).textFieldStyle(.roundedBorder).frame(width:64).accessibilityLabel("休息分钟")
                        Text("分钟（1–60）").foregroundStyle(.secondary)
                    }
                    Button("应用时长") {
                        do {
                            guard let first=Int(focusText),let second=Int(breakText) else{throw SkinError("请输入整数分钟。")}
                            try focus.applyDurations(focusMinutes:first,breakMinutes:second);reloadDrafts();error=nil
                        }catch{self.error=error.localizedDescription}
                    }
                }.disabled(focus.status != .ready)
                Toggle("每段完成时播放提示音",isOn:Binding(get:{focus.completionSoundEnabled},set:{value in
                    do{try focus.setCompletionSound(value);error=nil}catch{self.error=error.localizedDescription}
                }))
                Text("提示音默认关闭；手动安静、睡眠、模态或退出阻挡时不响，之后不补响。完成状态会在计时窗持续高亮，直到开始下一段或重置。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
                Text("每段结束后，由你手动开始休息或下一次专注。专注运行时暂时安静，暂停或结束后恢复；手动安静开关保留。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("桌面计时器独立于角色，可拖动顶部移动、点击图钉切换置顶。关闭小窗仍继续计时；菜单栏或角色右键的专注计时菜单可重新显示或召回。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("隐藏角色、关闭设置不暂停；睡眠时间计入倒计时。完成时若角色正隐藏、安静或交互被阻挡，可从菜单查看完成状态。退出结束本次计时，重开只保留时长。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
        }.onAppear{reloadDrafts()}.onChange(of:focus.focusMinutes){_,minutes in focusText=String(minutes)}
    }
    private func reloadDrafts(){focusText=String(focus.focusMinutes);breakText=String(focus.breakMinutes)}
}
