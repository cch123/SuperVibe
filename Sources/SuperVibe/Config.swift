import Foundation

enum PipelineStage: Equatable {
    case idle, recording, recognizing, translating, done, error
}

enum EngineMode: String {
    case cloud = "cloud"
    case vibeVoice = "vibevoice"
}

struct SuperVibeConfig {
    var pipelineURL = "wss://vibing-api-ccegdhbrg2d6bsd7.b02.azurefd.net/ws/pipeline"
    var pipelineTimeout: TimeInterval = 300

    var clientVersion: String { "0.1.0" }

    var deviceId: String {
        let key = "SuperVibe/device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}
