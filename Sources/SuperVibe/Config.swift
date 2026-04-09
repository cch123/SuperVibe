import Foundation

enum PipelineStage: Equatable {
    case idle, recording, recognizing, polishing, done, error
}

struct SuperVibeConfig {
    var pipelineURL = "wss://vibing-api-ccegdhbrg2d6bsd7.b02.azurefd.net/ws/pipeline"
    var pipelineTimeout: TimeInterval = 300

    var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

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
