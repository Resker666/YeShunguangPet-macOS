import AppKit
import PetCore

@MainActor final class FakeHotKeyRegistry:HotKeyRegistry {
    var onEvent:((UInt32,Bool)->Void)?
    var registered=[UInt32:ShortcutCombination]()
    var blocked=Set<ShortcutCombination>(),failedRemovals=Set<UInt32>()
    var registerCalls=0,disposeCalls=0
    func register(_ combination:ShortcutCombination,id:UInt32)throws {
        registerCalls+=1
        guard !blocked.contains(combination),registered[id]==nil,!registered.values.contains(combination) else{throw NSError(domain:"test.register",code:1)}
        registered[id]=combination
    }
    func unregister(id:UInt32)throws {
        guard !failedRemovals.contains(id) else{throw NSError(domain:"test.unregister",code:2)}
        registered[id]=nil
    }
    func dispose()throws {disposeCalls+=1;for id in registered.keys.sorted(){try unregister(id:id)};onEvent=nil}
    func emit(_ id:UInt32,down:Bool=true) {onEvent?(id,down)}
}
@MainActor final class ShortcutTestInput {var writeFails=false,allowsDispatch=true}
@MainActor final class ShortcutFixture {
    let directory:URL,settingsURL:URL,session:PetSession,registry:FakeHotKeyRegistry,controller:ShortcutController
    let input=ShortcutTestInput()
    static let a=ShortcutCombination(keyCode:0,modifiers:[.control,.option])
    static let b=ShortcutCombination(keyCode:1,modifiers:[.control,.option])
    init(bindings:[ShortcutBinding]=[],blocked:Set<ShortcutCombination>=[],corrupt:Bool=false)throws {
        _=NSApplication.shared
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        settingsURL=directory.appendingPathComponent("settings.json")
        if corrupt{try Data("broken".utf8).write(to:settingsURL)}else{try SettingsStore(url:settingsURL).save(.init(placement:nil,preferences:.init(keyboardShortcuts:bindings)))}
        let input=input
        let store=SettingsStore(url:settingsURL,write:{data,url in if input.writeFails{throw NSError(domain:"test.disk",code:3)};try data.write(to:url,options:.atomic)})
        session=PetSession(skin:skin,now:{.zero},settings:store,screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]})
        session.start()
        registry=FakeHotKeyRegistry();registry.blocked=blocked
        controller=ShortcutController(session:session,registry:registry,canDispatch:{input.allowsDispatch});controller.start()
    }
    func close(){input.writeFails=false;registry.failedRemovals=[];controller.dispose();session.prepareToExit();try? FileManager.default.removeItem(at:directory)}
}
