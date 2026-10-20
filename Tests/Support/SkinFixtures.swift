import Foundation
import XCTest

enum SkinFixtures {
    static let minimalManifest = Data(#"{"schemaVersion": 1,"id":"my-pet","name":"我的角色","cellWidth":32,"cellHeight":32,"columns":2,"rows":1,"animations":{"idle":{"durationsMs":[300,200],"loop":true}}}"#.utf8)
    static func replacing(_ old: String, with new: String, in data: Data = minimalManifest) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
    }
    static func manifest(_ changes: [String: Any]) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: minimalManifest) as! [String: Any]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}
