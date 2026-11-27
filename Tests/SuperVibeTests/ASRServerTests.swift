import XCTest
@testable import SuperVibe

/// End-to-end test of the Swift client against the real Python server and
/// model. Skipped unless SUPERVIBE_ASR_TEST_WAV points at a 24 kHz mono
/// Int16 WAV (see `make test-asr`), because it needs mlx-audio and several
/// GB of model weights.
final class ASRServerTests: XCTestCase {

    private func loadPCM() throws -> Data {
        guard let path = ProcessInfo.processInfo.environment["SUPERVIBE_ASR_TEST_WAV"], !path.isEmpty else {
            throw XCTSkip("SUPERVIBE_ASR_TEST_WAV not set")
        }
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))
        // Canonical 44-byte header as written by afconvert / the wave module.
        guard let dataTag = wav.range(of: Data("data".utf8)) else {
            throw XCTSkip("not a WAV file: \(path)")
        }
        return wav.subdata(in: (dataTag.upperBound + 4)..<wav.count)
    }

    private func makeClient() -> VibeVoiceSTT {
        let stt = VibeVoiceSTT()
        if let id = ProcessInfo.processInfo.environment["SUPERVIBE_ASR_TEST_MODEL"],
           let model = VibeVoiceSTT.availableModels.first(where: { $0.id == id }) {
            stt.selectModel(model, restart: false)
        }
        return stt
    }

    /// Audio sent in real-time-sized chunks; the session is committed late
    /// (after audio already arrived) to exercise the local buffering.
    func testStreamingSessionProducesDeltasAndDone() throws {
        let pcm = try loadPCM()
        let stt = makeClient()
        defer { stt.shutdown() }

        let done = expectation(description: "done")
        var deltas: [String] = []
        var final = ""
        stt.onDelta = { _, text in deltas.append(text) }
        stt.onDone = { _, text in final = text; done.fulfill() }
        stt.onError = { _, message in XCTFail("ASR error: \(message)"); done.fulfill() }

        let session = stt.openSession()
        let chunk = VibeVoiceSTT.inputSampleRate / 10 * 2   // 100 ms of Int16
        var offset = 0
        var committed = false
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            stt.sendAudio(session, pcm.subdata(in: offset..<end))
            offset = end
            if !committed, offset >= chunk * 5 {
                stt.commitSession(session, context: "SuperVibe, Kafka, Swift, Python")
                committed = true
            }
        }
        if !committed { stt.commitSession(session, context: "") }
        stt.finishSession(session)

        wait(for: [done], timeout: 300)
        XCTAssertFalse(final.isEmpty)
        XCTAssertFalse(final.contains("Speaker"), "speaker labels must be stripped")
        if stt.currentModel.streaming {
            XCTAssertEqual(deltas.joined().trimmingCharacters(in: .whitespacesAndNewlines), final)
        }
        if let expected = ProcessInfo.processInfo.environment["SUPERVIBE_ASR_TEST_EXPECT"], !expected.isEmpty {
            XCTAssertTrue(final.contains(expected), "expected \"\(expected)\" in \"\(final)\"")
        }
        print("ASR result (\(deltas.count) deltas): \(final)")
    }

    /// A cancelled session must stay silent, and the next session on the
    /// same server must work.
    func testCancelThenNewSession() throws {
        let pcm = try loadPCM()
        let stt = makeClient()
        defer { stt.shutdown() }

        let done = expectation(description: "second session done")
        var cancelledSessionEvents = 0
        var final = ""

        let first = stt.openSession()
        stt.onDelta = { id, _ in if id == first { cancelledSessionEvents += 1 } }
        stt.onDone = { id, text in
            if id == first { cancelledSessionEvents += 1 } else { final = text; done.fulfill() }
        }
        stt.onError = { _, message in XCTFail("ASR error: \(message)"); done.fulfill() }

        stt.commitSession(first, context: "")
        stt.sendAudio(first, pcm)
        stt.cancelSession(first)

        let second = stt.openSession()
        stt.commitSession(second, context: "")
        stt.sendAudio(second, pcm)
        stt.finishSession(second)

        wait(for: [done], timeout: 300)
        XCTAssertFalse(final.isEmpty)
        XCTAssertEqual(cancelledSessionEvents, 0)
    }

    /// Stopping before the context is committed and without any audio must
    /// still complete (with an empty result), not hang.
    func testEmptySessionCompletes() throws {
        _ = try loadPCM()
        let stt = makeClient()
        defer { stt.shutdown() }

        let done = expectation(description: "done")
        var final: String?
        stt.onDone = { _, text in final = text; done.fulfill() }
        stt.onError = { _, message in XCTFail("ASR error: \(message)"); done.fulfill() }

        let session = stt.openSession()
        stt.finishSession(session)          // before commit
        stt.commitSession(session, context: "")

        wait(for: [done], timeout: 300)
        XCTAssertEqual(final, "")
    }
}
