import Foundation

public enum ShortcutAction:String,Codable,CaseIterable,Sendable {
    case toggleVisibility,recall,toggleQuiet
    public var title:String {switch self{case .toggleVisibility:"显示 / 隐藏角色";case .recall:"召回角色";case .toggleQuiet:"切换安静模式"}}
}
public struct ShortcutModifiers:OptionSet,Codable,Hashable,Sendable {
    public let rawValue:UInt32
    public init(rawValue:UInt32){self.rawValue=rawValue}
    public static let command=Self(rawValue:1),option=Self(rawValue:2),control=Self(rawValue:4),shift=Self(rawValue:8)
    public init(from decoder:any Decoder)throws {rawValue=try decoder.singleValueContainer().decode(UInt32.self)}
    public func encode(to encoder:any Encoder)throws {var c=encoder.singleValueContainer();try c.encode(rawValue)}
}
public struct ShortcutCombination:Codable,Hashable,Sendable {
    public let keyCode:UInt32
    public let modifiers:ShortcutModifiers
    public init(keyCode:UInt32,modifiers:ShortcutModifiers){self.keyCode=keyCode;self.modifiers=modifiers}
    public var isValid:Bool {modifiers.rawValue & ~15 == 0 && modifiers.rawValue.nonzeroBitCount>=2 && !modifiers.intersection([.control,.option]).isEmpty && KeyboardShortcuts.keys.contains{$0.id==keyCode}}
    public var label:String {
        let prefix:[(ShortcutModifiers,String)]=[(.control,"⌃"),(.option,"⌥"),(.shift,"⇧"),(.command,"⌘")]
        return prefix.filter{modifiers.contains($0.0)}.map{$0.1}.joined()+(KeyboardShortcuts.keys.first{$0.id==keyCode}?.label ?? "?")
    }
}
public struct ShortcutBinding:Codable,Equatable,Sendable {
    public let action:ShortcutAction
    public let combination:ShortcutCombination
    public init(action:ShortcutAction,combination:ShortcutCombination){self.action=action;self.combination=combination}
}
public struct ShortcutKey:Identifiable,Sendable {public let id:UInt32;public let label:String}
public enum KeyboardShortcuts {
    public static let keys:[ShortcutKey] = {
        let letters:[UInt32]=[0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
        let numbers:[UInt32]=[29,18,19,20,21,23,22,26,28,25]
        let functions:[UInt32]=[122,120,99,118,96,97,98,100,101,109,103,111]
        return zip(letters,"ABCDEFGHIJKLMNOPQRSTUVWXYZ").map{ShortcutKey(id:$0.0,label:String($0.1))}+numbers.enumerated().map{ShortcutKey(id:$0.element,label:String($0.offset))}+functions.enumerated().map{ShortcutKey(id:$0.element,label:"F\($0.offset+1)")}
    }()
    public static func validate(_ bindings:[ShortcutBinding])throws {
        guard bindings.count<=3,bindings.allSatisfy({$0.combination.isValid}) else{throw SkinError("快捷键需选择有效按键及至少两个修饰键，并包含 Control 或 Option。")}
        guard Set(bindings.map(\.action)).count==bindings.count else{throw SkinError("同一动作不能保存多个快捷键。")}
        guard Set(bindings.map(\.combination)).count==bindings.count else{throw SkinError("此组合键已用于另一个桌宠动作。")}
    }
}
