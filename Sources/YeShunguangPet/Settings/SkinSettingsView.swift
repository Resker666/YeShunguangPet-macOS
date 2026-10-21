import SwiftUI
import PetCore

struct SkinSettingsView:View {
    @ObservedObject var model:SettingsModel
    let onChooseSkin:()->Void
    @State private var skinToDelete:SkinLibraryEntry?
    var body:some View {
        Form {
            Section("皮肤") {
                HStack(spacing:16) {
                    if let image=model.currentImage {
                        Image(decorative:image,scale:1).resizable().interpolation(.high).scaledToFit().frame(width:72,height:80)
                    }
                    Text(model.skinName).font(.headline)
                }
                HStack {
                    Button("选择皮肤…",action:onChooseSkin)
                    Button("恢复默认皮肤") { model.restoreDefaultSkin() }
                }.disabled(model.isBusy)
                if let package=model.candidate {
                    HStack(spacing:16) {
                        if let image=model.candidateImage {
                            Image(decorative:image,scale:1).resizable().interpolation(.high).scaledToFit().frame(width:72,height:80)
                        }
                        VStack(alignment:.leading,spacing:6) {
                            Text("待导入：\(package.skin.manifest.name)")
                            Text("\(package.skin.manifest.cellWidth) × \(package.skin.manifest.cellHeight) 点（100%）").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("导入并使用") { Task { await model.confirmImport() } }.buttonStyle(.borderedProminent)
                                Button("取消") { model.cancelSkinSelection() }
                            }.disabled(model.isBusy)
                        }
                    }
                }
                if model.isBusy { HStack { ProgressView().controlSize(.small); Text("正在处理皮肤…") } }
                if let error=model.skinError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let warning=model.skinWarning { Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("可将单个 ZIP、皮肤文件夹或 pet.json 拖到此窗口，也可点“选择皮肤…”。预览后确认才保存素材副本，原文件保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("已导入皮肤") {
                if model.libraryEntries.isEmpty { Text("导入后会显示在这里，可直接切换。").foregroundStyle(.secondary) }
                ForEach(model.libraryEntries) { entry in
                    HStack(spacing:12) {
                        if let image=entry.thumbnail {
                            Image(decorative:image,scale:1).resizable().scaledToFit().frame(width:52,height:56)
                        } else {
                            Image(systemName:"exclamationmark.triangle").frame(width:52,height:56).foregroundStyle(.secondary)
                        }
                        VStack(alignment:.leading,spacing:4) {
                            Text(entry.name)
                            if model.isCurrentSkin(id:entry.id) { Text("使用中").font(.caption).foregroundStyle(.secondary) }
                            if let error=entry.loadError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error) }
                        }
                        Spacer(minLength:4)
                        Button("使用") { Task { await model.useSkin(id:entry.id) } }
                            .disabled(model.isBusy || entry.loadError != nil || model.isCurrentSkin(id:entry.id))
                        Button { skinToDelete=entry } label: { Image(systemName:"trash") }
                            .accessibilityLabel("删除\(entry.name)")
                            .disabled(!model.canDeleteSkin(id:entry.id))
                    }
                }
                if let error=model.libraryError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Button("刷新皮肤列表") { Task { await model.reloadLibrary() } }.disabled(model.isBusy)
            }
        }.formStyle(.grouped)
        .alert(item:$skinToDelete) { entry in
            Alert(title:Text("删除皮肤？"),message:Text("将删除“\(entry.name)”的已导入副本，原始文件不受影响。"),primaryButton:.destructive(Text("删除")) {
                Task { await model.deleteSkin(id:entry.id) }
            },secondaryButton:.cancel(Text("取消")))
        }
    }
}
