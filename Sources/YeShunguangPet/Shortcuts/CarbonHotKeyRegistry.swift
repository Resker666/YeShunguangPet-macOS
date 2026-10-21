import AppKit
import Carbon
import PetCore

private final class HotKeyContext:@unchecked Sendable {
    @MainActor weak var registry:CarbonHotKeyRegistry?
    @MainActor init(_ registry:CarbonHotKeyRegistry){self.registry=registry}
}
private let petHotKeyHandler:EventHandlerUPP = {_,event,data in
    guard let event,let data else{return OSStatus(eventNotHandledErr)}
    var identifier=EventHotKeyID()
    let result=GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&identifier)
    guard result==noErr else{return result}
    let kind=GetEventKind(event)
    guard kind==UInt32(kEventHotKeyPressed) || kind==UInt32(kEventHotKeyReleased) else{return OSStatus(eventNotHandledErr)}
    let context=Unmanaged<HotKeyContext>.fromOpaque(data).takeUnretainedValue()
    let signature=identifier.signature,id=identifier.id,down=kind==UInt32(kEventHotKeyPressed)
    if Thread.isMainThread {return MainActor.assumeIsolated{context.registry?.receive(signature:signature,id:id,down:down)==true ? noErr : OSStatus(eventNotHandledErr)}}
    Task{@MainActor in _=context.registry?.receive(signature:signature,id:id,down:down)}
    return noErr
}
@MainActor final class CarbonHotKeyRegistry:HotKeyRegistry {
    var onEvent:((UInt32,Bool)->Void)?
    private static var nextSignature:UInt32=0x59534700
    private let signature:UInt32
    private var references=[UInt32:EventHotKeyRef]()
    private var handler:EventHandlerRef?
    private var context:UnsafeMutableRawPointer?
    private var disposed=false
    init(){Self.nextSignature &+= 1;signature=Self.nextSignature}
    private func installHandler()throws {
        guard handler==nil else{return}
        let retained=Unmanaged.passRetained(HotKeyContext(self)).toOpaque()
        var types=[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        var installed:EventHandlerRef?
        let status=InstallEventHandler(GetApplicationEventTarget(),petHotKeyHandler,types.count,&types,retained,&installed)
        guard status==noErr,let installed else{Unmanaged<HotKeyContext>.fromOpaque(retained).release();throw failure("建立快捷键事件处理器",status)}
        handler=installed;context=retained
    }
    func register(_ combination:ShortcutCombination,id:UInt32)throws {
        guard !disposed,combination.isValid,references[id]==nil else{throw SkinError("快捷键登记参数无效或服务已关闭。")}
        try installHandler()
        var modifiers:UInt32=0
        for (flag,value):(ShortcutModifiers,Int) in [(.command,cmdKey),(.option,optionKey),(.control,controlKey),(.shift,shiftKey)] {if combination.modifiers.contains(flag){modifiers |= UInt32(value)}}
        var reference:EventHotKeyRef?
        let status=RegisterEventHotKey(combination.keyCode,modifiers,EventHotKeyID(signature:signature,id:id),GetApplicationEventTarget(),OptionBits(kEventHotKeyExclusive),&reference)
        guard status==noErr,let reference else{throw failure("登记 \(combination.label)（可能已被系统或其他应用占用）",status)}
        references[id]=reference
    }
    func unregister(id:UInt32)throws {
        guard let reference=references[id] else{return}
        let status=UnregisterEventHotKey(reference)
        guard status==noErr else{throw failure("解除快捷键",status)}
        references[id]=nil
    }
    fileprivate func receive(signature:UInt32,id:UInt32,down:Bool)->Bool {
        guard !disposed,self.signature==signature,references[id] != nil else{return false}
        onEvent?(id,down);return true
    }
    func dispose()throws {
        disposed=true;onEvent=nil
        var errors=[String]()
        for id in references.keys.sorted(){do{try unregister(id:id)}catch{errors.append(error.localizedDescription)}}
        if let handler {
            let status=RemoveEventHandler(handler)
            if status==noErr {
                self.handler=nil
                if let context{Unmanaged<HotKeyContext>.fromOpaque(context).release();self.context=nil}
            }else{errors.append(failure("移除事件处理器",status).localizedDescription)}
        }
        // On a failed removal the retained context intentionally stays alive; its owner is weak.
        if !errors.isEmpty{throw SkinError(errors.joined(separator:"；"))}
    }
    private func failure(_ operation:String,_ status:OSStatus)->SkinError {SkinError("\(operation)失败（系统状态 \(status)）。")}
}
