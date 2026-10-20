public struct RuntimeGate {
    public var loaded=false, visible=false, sleeping=false, exiting=false
    public init() {}
    public var shouldRunFrames: Bool { loaded && visible && !sleeping && !exiting }
}
