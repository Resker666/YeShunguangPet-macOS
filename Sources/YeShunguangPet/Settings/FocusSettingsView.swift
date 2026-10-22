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
                if let error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
                Text("每段结束后，由你手动开始休息或下一次专注。专注运行时暂时安静，暂停或结束后恢复；手动安静开关保留。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("隐藏角色、关闭设置不暂停；睡眠时间计入倒计时。完成时若角色正隐藏、安静或交互被阻挡，可从菜单查看完成状态。退出结束本次计时，重开只保留时长。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
        }.onAppear{reloadDrafts()}
    }
    private func reloadDrafts(){focusText=String(focus.focusMinutes);breakText=String(focus.breakMinutes)}
}
