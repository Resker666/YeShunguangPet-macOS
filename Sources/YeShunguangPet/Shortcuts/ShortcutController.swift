import AppKit
import Combine
import PetCore

@MainActor protocol HotKeyRegistry:AnyObject {
    var onEvent:((UInt32,Bool)->Void)? {get set}
    func register(_ combination:ShortcutCombination,id:UInt32)throws
    func unregister(id:UInt32)throws
    func dispose()throws
}
struct ShortcutStatus:Equatable {
    let remembered:ShortcutCombination?,active:ShortcutCombination?
    let pendingCleanup:[ShortcutCombination]
    let message:String?
}
@MainActor final class ShortcutController:ObservableObject {
    private struct Registration {let action:ShortcutAction;let combination:ShortcutCombination;var enabled:Bool}
    @Published private(set) var statuses=[ShortcutAction:ShortcutStatus]()
    private weak var session:PetSession?
    private let registry:any HotKeyRegistry
    private let canDispatch:()->Bool
    private var entries=[UInt32:Registration](),held=Set<UInt32>()
    private var messages=[ShortcutAction:String]()
    private var nextID:UInt32=1
    private var started=false,disposed=false
    init(session:PetSession,registry:any HotKeyRegistry,canDispatch:@escaping ()->Bool) {
        self.session=session;self.registry=registry;self.canDispatch=canDispatch
        registry.onEvent={ [weak self] id,down in self?.receive(id,down:down) };refresh()
    }
    func start() {
        guard !started,!disposed,let session else{return};started=true
        for binding in session.preferences.keyboardShortcuts {
            do{_ = try register(binding.combination,action:binding.action,enabled:true)}
            catch{messages[binding.action]="已记住，但未激活：\(error.localizedDescription) 请重试或更改组合键。"}
        }
        refresh()
    }
    private func register(_ combination:ShortcutCombination,action:ShortcutAction,enabled:Bool)throws->UInt32 {
        guard nextID<UInt32.max else{throw SkinError("快捷键登记次数已达上限，请重开 App。")}
        let id=nextID;nextID+=1
        try registry.register(combination,id:id)
        entries[id]=Registration(action:action,combination:combination,enabled:enabled)
        return id
    }
    private func remove(_ id:UInt32)throws {
        try registry.unregister(id:id);entries[id]=nil;held.remove(id)
    }
    private func cleanup(_ action:ShortcutAction)throws {
        var errors=[String]()
        for id in entries.keys.sorted() where entries[id]?.action==action && entries[id]?.enabled==false {
            do{try remove(id)}catch{errors.append(error.localizedDescription)}
        }
        if !errors.isEmpty{throw SkinError("未保存的组合键仍被本 App 占用，重试释放："+errors.joined(separator:"；"))}
    }
    func apply(_ combination:ShortcutCombination?,to action:ShortcutAction) {
        guard !disposed,started,let session,!session.gate.exiting else{return}
        guard !session.protectedSettings else{messages[action]="原配置受保护，请先备份并重置。";refresh();return}
        let oldBindings=session.preferences.keyboardShortcuts
        let remembered=oldBindings.first{$0.action==action}?.combination
        var candidateBindings=oldBindings.filter{$0.action != action}
        if let combination{candidateBindings.append(.init(action:action,combination:combination))}
        do{try KeyboardShortcuts.validate(candidateBindings);try cleanup(action)}
        catch{messages[action]=error.localizedDescription;refresh();return}
        let old=entries.first{$0.value.action==action && $0.value.enabled}
        if remembered==combination {
            do {
                if let combination,old==nil{_ = try register(combination,action:action,enabled:true)}
                messages[action]=nil
            }catch{messages[action]="已记住，但未激活：\(error.localizedDescription)"}
            refresh();return
        }
        var candidateID:UInt32?
        do {if let combination{candidateID=try register(combination,action:action,enabled:false)}}
        catch{messages[action]="未更改：\(error.localizedDescription) 原快捷键保持不变。";refresh();return}
        do {if let old{try remove(old.key)}}
        catch {
            var message="旧快捷键未能解除，未保存：\(error.localizedDescription)"
            if let candidateID{do{try remove(candidateID)}catch{message+="；候选组合键未能释放：\(error.localizedDescription)"}}
            messages[action]=message;refresh();return
        }
        do {
            try session.saveKeyboardShortcuts(candidateBindings)
            if let candidateID{entries[candidateID]?.enabled=true}
            messages[action]=nil
        }catch {
            var message="保存失败，仍记住原快捷键：\(error.localizedDescription)"
            if let candidateID{do{try remove(candidateID)}catch{message+="；候选组合键未能释放：\(error.localizedDescription)"}}
            if let old {
                do{_ = try register(old.value.combination,action:action,enabled:true)}
                catch{message+="；原快捷键恢复失败，目前未激活：\(error.localizedDescription) 请重试。"}
            }
            messages[action]=message
        }
        refresh()
    }
    func retry(_ action:ShortcutAction) {
        apply(session?.preferences.keyboardShortcuts.first{$0.action==action}?.combination,to:action)
    }
    private func receive(_ id:UInt32,down:Bool) {
        guard !disposed,let entry=entries[id] else{return}
        if !down{held.remove(id);return}
        guard held.insert(id).inserted,entry.enabled,canDispatch(),let session,!session.gate.exiting,!session.gate.sleeping else{return}
        switch entry.action {
        case .toggleVisibility:session.setVisible(!session.isVisible)
        case .recall:session.recall()
        case .toggleQuiet:session.setQuiet(!session.isQuiet)
        }
    }
    private func refresh() {
        var next=[ShortcutAction:ShortcutStatus]()
        for action in ShortcutAction.allCases {
            let registrations=entries.sorted{$0.key<$1.key}.map(\.value).filter{$0.action==action}
            next[action]=ShortcutStatus(remembered:session?.preferences.keyboardShortcuts.first{$0.action==action}?.combination,active:registrations.first{$0.enabled}?.combination,pendingCleanup:registrations.filter{!$0.enabled}.map(\.combination),message:messages[action])
        }
        statuses=next
    }
    func dispose() {
        disposed=true;held=[];registry.onEvent=nil
        for id in entries.keys{entries[id]?.enabled=false}
        for id in entries.keys.sorted() {
            let action=entries[id]!.action
            do{try remove(id)}catch{messages[action]="解除快捷键失败：\(error.localizedDescription)"}
        }
        if entries.isEmpty {
            do{try registry.dispose()}
            catch{for action in ShortcutAction.allCases{messages[action]="移除快捷键处理器失败：\(error.localizedDescription)"}}
        }
        refresh()
    }
}
