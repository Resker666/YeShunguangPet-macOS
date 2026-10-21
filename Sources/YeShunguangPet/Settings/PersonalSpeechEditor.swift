import SwiftUI
import PetCore

private struct SpeechRemoval:Identifiable {let id:String}
struct PersonalSpeechEditor:View {
    @ObservedObject var model:SettingsModel
    private let targetID:String,generation:Int
    @State private var draft:[SpeechEvent:String]
    @State private var expanded=false
    @State private var error:String?
    @State private var removal:SpeechRemoval?
    init(model:SettingsModel) {
        self.model=model;targetID=model.currentSpeechID;generation=model.speechEditGeneration
        _draft=State(initialValue:Dictionary(uniqueKeysWithValues:SpeechEvent.allCases.map{($0,model.resolvedSpeech.lines(for:$0).joined(separator:"\n"))}))
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("当前：\(model.skinName)（\(targetID)）").font(.caption).textSelection(.enabled)
            DisclosureGroup("自定义当前角色台词",isExpanded:$expanded) {
                VStack(alignment:.leading,spacing:10) {
                    ForEach(SpeechEvent.allCases,id:\.self) {event in
                        VStack(alignment:.leading,spacing:4) {
                            Text(event.displayTitle).font(.subheadline)
                            TextEditor(text:Binding(get:{draft[event] ?? ""},set:{draft[event]=$0}))
                                .font(.body).frame(minHeight:64,maxHeight:100)
                                .border(.quaternary).accessibilityLabel(event.displayTitle)
                        }
                    }
                    Text("每行一句，每类最多8句；每句最多80个字符，部分符号按两个计。留空表示该类不说话。应用后保存，换角色、离开互动页或关窗会丢弃未应用的编辑。同ID皮肤共用台词。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("应用台词") {apply()}.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("pet-apply-personal-speech")
                        Button("恢复皮肤台词…") {removal=SpeechRemoval(id:targetID)}
                    }
                }.padding(.top,8)
            }
            if let error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
            if !model.preferences.speechOverrides.isEmpty {
                DisclosureGroup("已保存台词（\(model.preferences.speechOverrides.count)/16个角色）") {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(model.preferences.speechOverrides.keys.sorted(),id:\.self) {id in
                            HStack {Text(id).font(.caption).textSelection(.enabled);Spacer();Button("清除…"){removal=SpeechRemoval(id:id)}}
                        }
                    }.padding(.top,6)
                }
            }
            Text("仍需开启上方“显示互动台词”才显示气泡；不修改皮肤原文件。").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.canEditPersonalSpeech)
        .alert(item:$removal) {entry in
            Alert(title:Text("恢复皮肤台词？"),message:Text("将清除角色 \(entry.id) 已保存的个人台词，恢复使用皮肤或默认文案。"),primaryButton:.destructive(Text("清除个人台词")) {
                do{try model.removePersonalSpeech(for:entry.id);error=nil}catch{self.error=error.localizedDescription}
            },secondaryButton:.cancel(Text("取消")))
        }
    }
    private func apply() {
        do {
            let lines=try SpeechLines(click:PersonalSpeech.parse(draft[.click] ?? ""),drag:PersonalSpeech.parse(draft[.drag] ?? ""),focusCompleted:PersonalSpeech.parse(draft[.focusCompleted] ?? ""),breakCompleted:PersonalSpeech.parse(draft[.breakCompleted] ?? ""))
            try model.applyPersonalSpeech(lines,for:targetID,generation:generation);error=nil
        }catch{self.error=error.localizedDescription}
    }
}
private extension SpeechEvent {
    var displayTitle:String {switch self{case .click:return "点击回应";case .drag:return "拖动回应";case .focusCompleted:return "专注完成";case .breakCompleted:return "休息完成"}}
}
