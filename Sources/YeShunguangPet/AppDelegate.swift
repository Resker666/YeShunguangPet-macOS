import AppKit
import PetCore
import Darwin

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: PetSession?
    var status: StatusBarController?
    private var terminationSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM,SIG_IGN)
        let termination=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
        termination.setEventHandler { NSApp.terminate(nil) }; termination.resume(); terminationSignal=termination
        do {
            let options=try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
            guard let url=options.skinURL ?? Bundle.main.url(forResource:"pet",withExtension:"json",subdirectory:"Pets/YeShunguang") else { throw SkinError("缺少随附皮肤 pet.json") }
            let skin=try SkinLoader.load(manifestURL:url)
            let clock=ContinuousClock(), origin=ContinuousClock.now
            let settingsURL: URL
            if let path=ProcessInfo.processInfo.environment["YSGPET_SETTINGS_PATH"],path.hasPrefix("/") { settingsURL=URL(fileURLWithPath:path) }
            else { settingsURL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("YeShunguangPet-macOS/settings.json") }
            let session=PetSession(skin:skin,now:{origin.duration(to:clock.now)},settings:SettingsStore(url:settingsURL),screens:ScreenProvider.areas)
            self.session=session; status=StatusBarController(session:session,onQuit:{ NSApp.terminate(nil) }); session.start()
        } catch { status=StatusBarController(session:nil,error:error.localizedDescription,onQuit:{NSApp.terminate(nil)}) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session,!session.requestExit() else { return .terminateNow }
        let alert=NSAlert(); alert.messageText="位置未能保存"; alert.informativeText=session.persistenceError ?? "原配置保持不变。"
        alert.addButton(withTitle:"继续退出"); alert.addButton(withTitle:"取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let path=ProcessInfo.processInfo.environment["YSGPET_METRICS_PATH"],path.hasPrefix("/") {
            do { try session?.exportMetrics(to:URL(fileURLWithPath:path)) }
            catch { NSLog("运行指标未能写入：%@",error.localizedDescription) }
        }
        session?.prepareToExit(); status?.dispose(); terminationSignal?.cancel(); terminationSignal=nil
    }
}
