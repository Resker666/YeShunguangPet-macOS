import AppKit
import XCTest
import PetCore

@MainActor final class LocalVoiceEngineWindowTests: XCTestCase {
    private func descendants<T:NSView>(_ v:NSView,_ t:T.Type)->[T] { (v as? T).map { [$0] } ?? v.subviews.flatMap { descendants($0,t) } }
    private func configure(_ f:ChatControllerFixture,supported:Bool = true,hooks:LocalVoiceEngineStore.Hooks = .live) async throws -> (ChatLocalVoiceEngineController,ControlledEngineProbe,ControlledVoiceOutput) {
        let output = ControlledVoiceOutput(), probe = ControlledEngineProbe()
        f.controller.configureVoice(services:.init(input:ControlledVoiceInput(),output:output),now:{ .zero })
        f.controller.configureLocalVoiceEngine(worker:LocalVoiceEngineWorker(dataRoot:f.root,hooks:hooks),probe:probe,isSupported:supported)
        try await chatEventually { f.controller.localVoices?.isLoaded == true && f.controller.localEngine?.isBusy == false }
        return (try XCTUnwrap(f.controller.localEngine),probe,output)
    }
    func testPreviewRequiresConfirmationAndDoesNotBindOrEnableVoice() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let (model,probe,output) = try await configure(f)
        let full = ChatWindowController(controller:f.controller,onPresentationChange:{ _ in }); defer { full.dispose() }
        full.present(); full.selectPage(4)
        model.preview(folder:try LocalVoiceEngineFixtures.folder(f.root)); await model.waitForPending(); full.render()
        let view = try XCTUnwrap(descendants(full.pageScroll,ChatLocalVoiceEngineView.self).first)
        XCTAssertTrue(descendants(view,NSButton.self).contains { $0.title == "确认安装引擎" && $0.isEnabled })
        XCTAssertEqual(probe.runs,0); XCTAssertTrue(output.spoken.isEmpty); XCTAssertTrue(f.controller.localVoices?.index.packages.isEmpty == true)
        XCTAssertFalse(f.controller.voice?.settings.enabledForSession == true)
        full.selectPage(0); XCTAssertNil(model.preview); await f.close()
    }
    func testCompactScrollableViewExposesCancelAndRetry() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let fail = EngineFailureFlag(); var hooks = LocalVoiceEngineStore.Hooks.live
        hooks.beforeCommit = { if fail.value { throw LocalVoiceError("activation failure") } }
        let (model,probe,_) = try await configure(f,hooks:hooks), folder = try LocalVoiceEngineFixtures.folder(f.root)
        let full = ChatWindowController(controller:f.controller,onPresentationChange:{ _ in }); defer { full.dispose() }
        full.present(); full.selectPage(4)
        model.preview(folder:folder); await model.waitForPending(); model.confirmInstall(); await model.waitForPending()
        XCTAssertTrue(model.hasUnsaved); XCTAssertEqual(probe.runs,1)
        let directory = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/portable-voice-engine-validation/ui")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            full.window?.appearance = NSAppearance(named:appearance); full.window?.setContentSize(.init(width:440,height:420));full.render();full.window?.contentView?.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(descendants(full.pageScroll,ChatLocalVoiceEngineView.self).first)
            XCTAssertLessThanOrEqual(view.bounds.width,full.pageScroll.contentSize.width)
            for title in ["安装或修复本地引擎…","检查当前引擎","重试引擎切换或清理","取消引擎安装"] {
                let button = try XCTUnwrap(descendants(view,NSButton.self).first { $0.title == title })
                if !button.isHidden {
                    _ = button.scrollToVisible(button.bounds)
                    let document = try XCTUnwrap(full.pageScroll.documentView)
                    XCTAssertTrue(button.convert(button.bounds,to:document).intersects(full.pageScroll.documentVisibleRect))
                }
            }
            let retry = try XCTUnwrap(descendants(view,NSButton.self).first { $0.title == "重试引擎切换或清理" }); XCTAssertTrue(retry.isEnabled)
            _ = view.scrollToVisible(view.bounds)
            let visible = try XCTUnwrap(full.window?.contentView), image = try XCTUnwrap(visible.bitmapImageRepForCachingDisplay(in:visible.bounds))
            visible.cacheDisplay(in:visible.bounds,to:image);try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("engine-"+name+".png"))
        }
        model.cancelInstallation(); await model.waitForPending(); await f.close()
    }
    func testIntelAndUnconfiguredStatesRemainUsable() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let (model,probe,output) = try await configure(f,supported:false)
        let view = ChatLocalVoiceEngineView(controller:f.controller,hasBlockingModal:{ false })
        XCTAssertFalse(try XCTUnwrap(descendants(view,NSButton.self).first { $0.title == "安装或修复本地引擎…" }).isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("LocalVoice").path))
        model.preview(folder:try LocalVoiceEngineFixtures.folder(f.root));await model.waitForPending();XCTAssertNil(model.preview)
        XCTAssertEqual(probe.runs,0); XCTAssertTrue(output.spoken.isEmpty)
        f.controller.setDraft("Intel文字仍可用");XCTAssertTrue(f.controller.canSend)
        await f.close()
    }
}
