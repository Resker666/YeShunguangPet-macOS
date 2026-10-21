import Foundation

public enum ManifestDecoder {
    private struct Object {
        let values: [String:JSONValue], path: String
        init(_ value: JSONValue, keys: [String], path: String) throws {
            guard case .object(let values) = value else { throw SkinError("\(path) 必须是对象") }
            guard Set(values.keys).isSubset(of:Set(keys)) else { throw SkinError("\(path) 包含未知字段") }
            self.values=values; self.path=path
        }
        func int(_ key: String, default fallback: Int? = nil) throws -> Int {
            if values[key] == nil, let fallback { return fallback }
            guard case .number(let text) = values[key], !text.contains(where:{ ".eE".contains($0) }), let n=Int(text), n >= Int32.min, n <= Int32.max else { throw SkinError("\(path).\(key) 必须为整数") }
            return n
        }
        func string(_ key: String, default fallback: String? = nil) throws -> String {
            if values[key] == nil, let fallback { return fallback }
            guard case .string(let s) = values[key] else { throw SkinError("\(path).\(key) 必须为字符串") }; return s
        }
        func bool(_ key: String, default fallback: Bool = false) throws -> Bool {
            guard let v=values[key] else { return fallback }
            guard case .bool(let b)=v else { throw SkinError("\(path).\(key) 必须为布尔值") }; return b
        }
        func array(_ key: String, default fallback: [JSONValue]? = nil) throws -> [JSONValue] {
            if values[key] == nil, let fallback { return fallback }
            guard case .array(let a)=values[key] else { throw SkinError("\(path).\(key) 必须为数组") }; return a
        }
    }
    private static func check(_ valid: Bool, _ field: String) throws { if !valid { throw SkinError("皮肤字段无效：\(field)") } }
    private static func hasControl(_ s: String) -> Bool { s.unicodeScalars.contains { $0.properties.generalCategory == .control } }
    private static func present(_ v: JSONValue?) -> JSONValue? { guard let v else { return nil }; if case .null=v { return nil }; return v }
    public static func isValidID(_ id:String)->Bool {
        let reserved=["con","prn","aux","nul"]+(1...9).flatMap { ["com\($0)","lpt\($0)"] }
        return id.range(of:"^[a-z][a-z0-9-]{0,63}$",options:.regularExpression) != nil && !id.contains("\n") && !reserved.contains(id)
    }
    public static func decode(_ data: Data) throws -> PetManifest {
        let root=try Object(StrictJSON.parse(data),keys:["schemaVersion","id","name","description","spriteSheet","cellWidth","cellHeight","columns","rows","animations","lookDirections","speech","behavior"],path:"pet")
        let version=try root.int("schemaVersion"), id=try root.string("id"), name=try root.string("name"), description=try root.string("description",default:""), sheet=try root.string("spriteSheet",default:"spritesheet.png")
        try check(version==1,"schemaVersion")
        try check(isValidID(id),"id")
        try check(!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && name.utf16.count<=64 && !hasControl(name) && description.utf16.count<=400,"name/description")
        try check(!sheet.isEmpty && sheet.utf16.count<=100 && sheet.lowercased().hasSuffix(".png") && !sheet.contains(where:{ "/\\<>:\"|?*".contains($0) }) && !hasControl(sheet),"spriteSheet")
        let w=try root.int("cellWidth"), h=try root.int("cellHeight"), cols=try root.int("columns"), rows=try root.int("rows")
        try check((16...512).contains(w) && (16...512).contains(h) && (1...64).contains(cols) && (1...64).contains(rows),"grid")
        try check(w*cols<=8192 && h*rows<=8192 && w*cols*h*rows<=16777216,"image dimensions")
        guard case .object(let actionObjects)=root.values["animations"] else { throw SkinError("animations 必须为动作表") }
        var animations: [PetAction:AnimationDefinition]=[:]
        for (key,value) in actionObjects {
            guard let action=PetAction(rawValue:key) else { throw SkinError("未知动作：\(key)") }
            let a=try Object(value,keys:["row","startColumn","durationsMs","loop"],path:key)
            let r=try a.int("row",default:0), c=try a.int("startColumn",default:0), loop=try a.bool("loop")
            let times=try a.array("durationsMs").map { v -> Int in let o=try Object(.object(["n":v]),keys:["n"],path:key); return try o.int("n") }
            try check(r>=0 && r<rows && c>=0 && c<cols && !times.isEmpty && times.count<=cols-c && times.allSatisfy{(20...10000).contains($0)},key)
            try check(![PetAction.waving,.jumping,.failed].contains(action) || !loop,key+".loop")
            animations[action]=AnimationDefinition(row:r,startColumn:c,durationsMs:times,loop:loop)
        }
        try check(animations[.idle]?.loop==true,"idle.loop")
        let look=try root.array("lookDirections",default:[]).map { v -> FrameLocation in
            let o=try Object(v,keys:["row","column"],path:"lookDirections"); let r=try o.int("row",default:0), c=try o.int("column",default:0)
            try check(r>=0 && r<rows && c>=0 && c<cols,"lookDirections coordinate"); return FrameLocation(row:r,column:c)
        }
        try check(look.isEmpty || look.count==16,"lookDirections count")
        var speech: SpeechLines?
        if let value=present(root.values["speech"]) {
            let o=try Object(value,keys:["click","drag","focusCompleted","breakCompleted"],path:"speech")
            func lines(_ key: String) throws -> [String] {
                let a=try o.array(key,default:[]).map { v -> String in guard case .string(let s)=v else { throw SkinError("speech.\(key) 必须为文本") }; try check(!s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && s.utf16.count<=80 && !hasControl(s),"speech.\(key)"); return s }
                try check(a.count<=8,"speech.\(key) count"); return a
            }
            speech=try SpeechLines(click:lines("click"),drag:lines("drag"),focusCompleted:lines("focusCompleted"),breakCompleted:lines("breakCompleted"))
        }
        var behavior: PetBehaviorRules?
        if let value=present(root.values["behavior"]) {
            let o=try Object(value,keys:["schemaVersion","rules"],path:"behavior"), v=try o.int("schemaVersion",default:1)
            try check(v==1,"behavior.schemaVersion")
            let entries=try o.array("rules",default:[]); try check(entries.count<=9,"behavior.rules count"); var seen=Set<String>()
            let rules=try entries.map { value -> PetBehaviorRule in
                let rule=try Object(value,keys:["condition","action","weight","cooldownSeconds"],path:"behavior.rules")
                let condition=try rule.string("condition",default:"any"), key=try rule.string("action",default:"waving"), weight=try rule.int("weight",default:1), cooldown=try rule.int("cooldownSeconds",default:30)
                guard let action=PetAction(rawValue:key), [.waving,.jumping,.failed].contains(action), let animation=animations[action] else { throw SkinError("behavior 引用的动作无效") }
                try check(["any","cursorNear","cursorFar"].contains(condition) && (1...100).contains(weight) && (5...3600).contains(cooldown) && !animation.loop && animation.durationsMs.reduce(0,+)<=30000 && seen.insert(condition+":"+key).inserted,"behavior.rules")
                return PetBehaviorRule(condition:condition,action:action,weight:weight,cooldownSeconds:cooldown)
            }
            behavior=PetBehaviorRules(schemaVersion:v,rules:rules)
        }
        return PetManifest(schemaVersion:version,id:id,name:name,description:description,spriteSheet:sheet,cellWidth:w,cellHeight:h,columns:cols,rows:rows,animations:animations,lookDirections:look,speech:speech,behavior:behavior)
    }
}
