import AppKit
import CoreGraphics
import PetCore

@MainActor enum ScreenProvider {
    static func areas() -> [ScreenArea] {
        NSScreen.screens.enumerated().map { index, screen in
            let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let display=CGDirectDisplayID(number?.uint32Value ?? 0)
            let id: String
            if let unmanaged=CGDisplayCreateUUIDFromDisplayID(display) {
                id=CFUUIDCreateString(nil,unmanaged.takeRetainedValue()) as String
            } else { id="display-\(display)" }
            return ScreenArea(id:id,visibleFrame:screen.visibleFrame,isPrimary:index==0)
        }
    }
}
