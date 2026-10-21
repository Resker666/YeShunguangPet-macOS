import AppKit
import PetCore

@MainActor final class QuickSkinMenus:NSObject {
    let menus=[NSMenu(),NSMenu()]
    private weak var session:PetSession?
    private let model:SettingsModel,canDispatch:()->Bool,onManage:()->Void
    private var refreshTask:Task<Void,Never>?,switchTask:Task<Void,Never>?
    private var disposed=false
    init(session:PetSession,model:SettingsModel,canDispatch:@escaping()->Bool,onManage:@escaping()->Void) {
        self.session=session;self.model=model;self.canDispatch=canDispatch;self.onManage=onManage
        super.init()
        for menu in menus {menu.autoenablesItems=false}
        model.onSkinStateChange = {[weak self] in self?.refresh()}
        refresh();reload()
    }
    private var canSwitch:Bool { !disposed && canDispatch() && !model.isBusy && !model.isTerminating && switchTask==nil && session?.protectedSettings==false }
    func reload() {
        guard !disposed,canDispatch(),!model.isBusy,!model.isTerminating,refreshTask==nil,switchTask==nil else{return}
        refreshTask=Task{[weak self] in
            guard let self else{return}
            defer{self.refreshTask=nil;self.refresh()}
            guard !Task.isCancelled,!self.disposed,!self.model.isTerminating else{return}
            await self.model.reloadLibrary()
        }
        refresh()
    }
    func refresh() {
        guard !disposed,let session else{return}
        func label(_ text:String)->String {
            let single=text.components(separatedBy:.whitespacesAndNewlines).filter{!$0.isEmpty}.joined(separator:" ")
            return single.count>48 ? String(single.prefix(47))+"…" : single
        }
        let nameCounts=Dictionary(grouping:model.libraryEntries,by:{label($0.name)}).mapValues(\.count)
        for menu in menus {
            let previous=Dictionary(uniqueKeysWithValues:menu.items.compactMap{item in (item.representedObject as? String).map{($0,item)}})
            menu.removeAllItems()
            func add(_ key:String,_ title:String,_ action:Selector?,enabled:Bool=true,checked:Bool=false,tip:String?=nil) {
                let item=previous[key] ?? NSMenuItem(title:title,action:action,keyEquivalent:"")
                item.title=title;item.action=action;item.target=self;item.representedObject=key;item.isEnabled=enabled;item.state=checked ? .on : .off;item.toolTip=tip
                menu.addItem(item)
            }
            add("default","默认："+label(session.defaultSkin.manifest.name),#selector(choose(_:)),enabled:canSwitch,checked:session.skin.directory==session.defaultSkin.directory)
            for entry in model.libraryEntries {
                let sameName=(nameCounts[label(entry.name)] ?? 0)>1
                let title=label(entry.name)+(sameName ? "（\(entry.id.prefix(8))）" : "")
                add(entry.id,title,#selector(choose(_:)),enabled:canSwitch && entry.loadError==nil,checked:model.isCurrentSkin(id:entry.id),tip:entry.loadError ?? entry.name)
            }
            if refreshTask != nil {add("loading","正在读取皮肤…",nil,enabled:false)}
            else if model.libraryEntries.isEmpty && model.libraryError==nil {add("empty","尚无已导入皮肤",nil,enabled:false)}
            if let error=model.libraryError {add("list-error","皮肤列表更新失败（重试）",#selector(retry),enabled:canDispatch() && !model.isBusy && !model.isTerminating,tip:error)}
            if let error=model.skinError {add("skin-error","皮肤操作失败（查看设置…）",#selector(manage),enabled:canDispatch() && !model.isTerminating,tip:error)}
            menu.addItem(.separator())
            add("manage","管理皮肤…",#selector(manage),enabled:canDispatch() && !model.isTerminating)
        }
    }
    @objc private func choose(_ item:NSMenuItem) {
        guard canSwitch,let id=item.representedObject as? String,let session else{return}
        guard id=="default" ? session.skin.directory != session.defaultSkin.directory : !model.isCurrentSkin(id:id) else{return}
        // Menu tracking can defer main-actor tasks. A cached choice takes priority
        // over a refresh that has been queued but has not entered the shared model.
        refreshTask?.cancel()
        switchTask=Task{[weak self] in
            guard let self else{return}
            defer{self.switchTask=nil;self.refresh()}
            guard !Task.isCancelled,!self.disposed,!self.model.isTerminating,self.canDispatch() else{return}
            if id=="default" {self.model.restoreDefaultSkin()}
            else {await self.model.useSkin(id:id,cancelWithPreview:false)}
        }
        refresh()
    }
    @objc private func retry(){reload()}
    @objc private func manage(){guard !disposed,canDispatch(),!model.isTerminating else{return};onManage()}
    func cancel(){refreshTask?.cancel();switchTask?.cancel();refresh()}
    func dispose(){disposed=true;cancel();model.onSkinStateChange=nil;for menu in menus{menu.cancelTracking();menu.delegate=nil;menu.removeAllItems()}}
}
