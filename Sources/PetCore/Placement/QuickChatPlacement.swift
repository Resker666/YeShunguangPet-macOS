import Foundation
import CoreGraphics

public enum QuickChatPlacement {
    public static func frame(anchor: CGRect, size: CGSize, screens: [ScreenArea]) -> CGRect? {
        guard WindowPlacement.valid(anchor), size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let valid = screens.filter { WindowPlacement.valid($0.visibleFrame) && $0.visibleFrame.width > 16 && $0.visibleFrame.height > 16 }
        func area(_ screen: ScreenArea) -> CGFloat { let r = anchor.intersection(screen.visibleFrame); return r.isNull ? 0 : r.width * r.height }
        func distance(_ screen: ScreenArea) -> CGFloat {
            let r = screen.visibleFrame, x = max(r.minX - anchor.midX, 0, anchor.midX - r.maxX), y = max(r.minY - anchor.midY, 0, anchor.midY - r.maxY)
            return x * x + y * y
        }
        guard let screen = valid.max(by: { area($0) == area($1) ? distance($0) > distance($1) : area($0) < area($1) }) else { return nil }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        func x(_ value: CGFloat) -> CGFloat { min(max(bounds.minX, value), bounds.maxX - size.width) }
        func y(_ value: CGFloat) -> CGFloat { min(max(bounds.minY, value), bounds.maxY - size.height) }
        let right = CGRect(origin: .init(x: anchor.maxX + 8, y: y(anchor.maxY - size.height)), size: size)
        let left = CGRect(origin: .init(x: anchor.minX - 8 - size.width, y: right.minY), size: size)
        let top = CGRect(origin: .init(x: x(anchor.midX - size.width / 2), y: anchor.maxY + 8), size: size)
        for candidate in [right, left, top] where bounds.contains(candidate) { return candidate }
        return CGRect(origin: .init(x: x(right.minX), y: y(right.minY)), size: size)
    }
}
