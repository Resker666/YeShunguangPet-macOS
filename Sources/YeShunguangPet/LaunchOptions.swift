import Foundation
import PetCore
struct LaunchOptions {
    let skinURL: URL?
    static func parse(_ arguments: [String]) throws -> Self {
        if arguments.isEmpty { return .init(skinURL:nil) }
        guard arguments.count==2,arguments[0]=="--skin",arguments[1].hasPrefix("/") else { throw SkinError("启动参数应为 --skin /绝对路径/pet.json") }
        return .init(skinURL:URL(fileURLWithPath:arguments[1]))
    }
}
