import AppKit
import PetCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: PetSession?
    var status: StatusBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let options=try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
            guard let url=options.skinURL ?? Bundle.main.url(forResource:"pet",withExtension:"json",subdirectory:"Pets/YeShunguang") else { throw SkinError("缺少随附皮肤 pet.json") }
            let skin=try SkinLoader.load(manifestURL:url)
            let clock=ContinuousClock(), origin=ContinuousClock.now
            let session=PetSession(skin:skin,now:{origin.duration(to:clock.now)})
            self.session=session; status=StatusBarController(session:session,onQuit:{ NSApp.terminate(nil) }); session.start()
        } catch { status=StatusBarController(session:nil,error:error.localizedDescription,onQuit:{NSApp.terminate(nil)}) }
    }
    func applicationWillTerminate(_ notification: Notification) { session?.prepareToExit(); status?.dispose() }
}
