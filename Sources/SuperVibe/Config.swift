import Foundation

enum PipelineStage: Equatable {
    case idle, recording, recognizing, translating, done, error
}
