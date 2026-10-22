import PetCore

extension PetSession {
    func saveFocusCompletionSound(_ enabled:Bool)throws {
        var candidate=preferences;candidate.focusCompletionSound=enabled
        try commitCompanionPreferences(candidate)
    }
    func saveFocusWindow(_ value:FocusWindowPreferences)throws {
        var candidate=preferences;candidate.focusWindow=value
        try commitCompanionPreferences(candidate)
    }
    func saveSpeechOverrides(_ overrides:[String:SpeechLines])throws {
        try PersonalSpeech.validate(overrides)
        var candidate=preferences;candidate.speechOverrides=overrides
        try commitCompanionPreferences(candidate)
    }
    func saveFocusDurations(focusMinutes:Int,breakMinutes:Int)throws {
        guard (1...120).contains(focusMinutes),(1...60).contains(breakMinutes) else{throw SkinError("专注请输入1–120分钟，休息请输入1–60分钟。")}
        var candidate=preferences;candidate.focusMinutes=focusMinutes;candidate.breakMinutes=breakMinutes
        try commitCompanionPreferences(candidate)
    }
    func presentFocusCompletion(_ phase:FocusPhase) {
        guard canPresentFocusCompletion else{return}
        play(phase == .focus ? .waving : .jumping)
        requestSpeech(phase == .focus ? .focusCompleted : .breakCompleted)
    }
}
