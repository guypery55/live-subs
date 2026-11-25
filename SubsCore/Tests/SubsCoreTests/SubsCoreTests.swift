import Foundation
import XCTest
@testable import SubsCore

final class ProtocolTests: XCTestCase {
    func testStartRequestJSON() throws {
        let json = try StartRequest.hebrewToEnglish().jsonString()
        XCTAssertEqual(json, #"{"audio_format":"pcm_s16le","enable_endpoint_detection":true,"language_hints":["he"],"model":"stt-rt-v6","num_channels":1,"sample_rate":16000,"translation":{"target_language":"en","type":"one_way"}}"#)
        XCTAssertFalse(json.contains("api_key"), "the key belongs in the Authorization header")
    }

    func testDecodeTokens() throws {
        let r = try SonioxResponse.decode(#"""
        {"tokens":[{"text":"שלום","start_ms":600,"end_ms":760,"confidence":0.97,"is_final":true,"translation_status":"original","language":"he"},
                   {"text":"Hello","is_final":false,"translation_status":"translation","language":"en","source_language":"he"},
                   {"text":"<end>","is_final":true}],
         "final_audio_proc_ms":760,"total_audio_proc_ms":880}
        """#)
        XCTAssertEqual(r.tokens.count, 3)
        XCTAssertEqual(r.tokens[0].role(), .source)
        XCTAssertEqual(r.tokens[0].startMs, 600)
        XCTAssertTrue(r.tokens[0].isFinal)
        XCTAssertEqual(r.tokens[1].role(), .target)
        XCTAssertFalse(r.tokens[1].isFinal)
        XCTAssertEqual(r.tokens[2].role(), .marker)
        XCTAssertFalse(r.isError)
        XCTAssertFalse(r.finished)
    }

    func testDecodeErrorAndFinished() throws {
        let e = try SonioxResponse.decode(#"{"tokens":[],"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key."}"#)
        XCTAssertTrue(e.isError)
        XCTAssertEqual(StreamProblem.from(errorCode: e.errorCode, errorType: e.errorType), .badKey)
        let f = try SonioxResponse.decode(#"{"tokens":[],"final_audio_proc_ms":1560,"total_audio_proc_ms":1680,"finished":true}"#)
        XCTAssertTrue(f.finished)
        let pong = try SonioxResponse.decode(#"{"type":"pong","id":7}"#)
        XCTAssertTrue(pong.tokens.isEmpty)
    }

    func testUntranslatedEnglishSpeechGoesToTheEnglishLine() {
        XCTAssertEqual(SonioxToken(text: "OK", isFinal: true, translationStatus: "none", language: "en").role(), .target)
        XCTAssertEqual(SonioxToken(text: "כן", isFinal: true, translationStatus: "none", language: "he").role(), .source)
    }

    func testProblemMapping() {
        XCTAssertEqual(StreamProblem.from(errorCode: 402, errorType: "organization_balance_exhausted"), .noCredit)
        XCTAssertEqual(StreamProblem.from(errorCode: 400, errorType: "model_not_available"), .needsUpdate)
        XCTAssertEqual(StreamProblem.from(errorCode: 408, errorType: "request_timeout"), .temporary)
        XCTAssertEqual(StreamProblem.from(errorCode: 413, errorType: "max_duration_reached"), .temporary)
        XCTAssertEqual(StreamProblem.from(errorCode: 503, errorType: "service_unavailable"), .temporary)
        XCTAssertTrue(StreamProblem.temporary.isRetryable)
        XCTAssertFalse(StreamProblem.badKey.isRetryable)
        XCTAssertNil(StreamProblem.fromKeyCheck(status: 200))
        XCTAssertEqual(StreamProblem.fromKeyCheck(status: 401), .badKey)
    }

    func testReconnectBackoff() {
        var p = ReconnectPolicy(delays: [1, 2, 4])
        XCTAssertEqual([p.nextDelay(), p.nextDelay(), p.nextDelay(), p.nextDelay()], [1, 2, 4, 4])
        p.reset()
        XCTAssertEqual(p.nextDelay(), 1)
    }
}

final class WrapperTests: XCTestCase {
    func testShortTextIsOneLine() {
        XCTAssertEqual(CaptionWrapper.lastLines(settled: "Hello there", pending: "", width: 20, maxLines: 2),
                       [CaptionLine(settled: "Hello there")])
    }

    func testKeepsOnlyTheNewestLines() {
        let lines = CaptionWrapper.lastLines(settled: "one two three four five six", pending: "", width: 9, maxLines: 2)
        XCTAssertEqual(lines.map(\.text), ["four five", "six"])
    }

    func testPendingPartIsSeparated() {
        let lines = CaptionWrapper.lastLines(settled: "I went to the ", pending: "market today", width: 40, maxLines: 2)
        XCTAssertEqual(lines, [CaptionLine(settled: "I went to the", pending: " market today")])
    }

    func testWordSplitAcrossSettledAndPending() {
        let lines = CaptionWrapper.lastLines(settled: "good morn", pending: "ing", width: 40, maxLines: 2)
        XCTAssertEqual(lines, [CaptionLine(settled: "good morn", pending: "ing")])
    }

    func testCollapsesWhitespaceAndSplitsLongWords() {
        XCTAssertEqual(CaptionWrapper.lastLines(settled: "  a   b  ", pending: " ", width: 10, maxLines: 2).map(\.text), ["a b"])
        XCTAssertEqual(CaptionWrapper.lastLines(settled: "abcdefghij", pending: "", width: 4, maxLines: 3).map(\.text),
                       ["abcd", "efgh", "ij"])
        XCTAssertEqual(CaptionWrapper.lastLines(settled: " ", pending: "", width: 4, maxLines: 2), [])
    }

    func testHebrewText() {
        let lines = CaptionWrapper.lastLines(settled: "שלום לכולם ", pending: "מה נשמע", width: 60, maxLines: 1)
        XCTAssertEqual(lines.first?.text, "שלום לכולם מה נשמע")
        XCTAssertEqual(lines.first?.settled, "שלום לכולם")
    }
}

final class AssemblerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func tok(_ text: String, final: Bool, en: Bool) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, translationStatus: en ? "translation" : "original", language: en ? "en" : "he")
    }

    func testPendingIsReplacedAndFinalAccumulates() {
        var a = SubtitleAssembler()
        a.apply(SonioxResponse(tokens: [tok("Hel", final: false, en: true)]), at: t0)
        XCTAssertEqual(a.frame(at: t0).english, [CaptionLine(settled: "", pending: "Hel")])
        a.apply(SonioxResponse(tokens: [tok("Hello", final: true, en: true), tok(" wor", final: false, en: true)]), at: t0)
        XCTAssertEqual(a.frame(at: t0).english, [CaptionLine(settled: "Hello", pending: " wor")])
        a.apply(SonioxResponse(tokens: [tok(" world", final: true, en: true)]), at: t0)
        XCTAssertEqual(a.frame(at: t0).english, [CaptionLine(settled: "Hello world")])
    }

    func testHebrewAndEnglishAreSeparateAndMarkersHidden() {
        var a = SubtitleAssembler()
        a.apply(SonioxResponse(tokens: [tok("שלום", final: true, en: false), tok("Hi", final: true, en: true),
                                        SonioxToken(text: "<end>", isFinal: true)]), at: t0)
        let f = a.frame(at: t0)
        XCTAssertEqual(f.english.map(\.text), ["Hi"])
        XCTAssertEqual(f.hebrew.map(\.text), ["שלום"])
    }

    func testFadesAfterSilenceAndStartsClean() {
        var a = SubtitleAssembler(fadeAfter: 4)
        a.apply(SonioxResponse(tokens: [tok("Old line", final: true, en: true)]), at: t0)
        XCTAssertFalse(a.frame(at: t0.addingTimeInterval(3.9)).isEmpty)
        XCTAssertTrue(a.frame(at: t0.addingTimeInterval(4)).isEmpty)
        // Empty responses (keepalive answers, silence) don't revive it.
        a.apply(SonioxResponse(tokens: []), at: t0.addingTimeInterval(5))
        XCTAssertTrue(a.frame(at: t0.addingTimeInterval(5)).isEmpty)
        // New speech after the pause starts on a clean screen.
        a.apply(SonioxResponse(tokens: [tok(" New", final: true, en: true)]), at: t0.addingTimeInterval(6))
        XCTAssertEqual(a.frame(at: t0.addingTimeInterval(6)).english.map(\.text), ["New"])
    }

    func testRollingWindowShowsNewestTwoLines() {
        var a = SubtitleAssembler(englishWidth: 10, englishLines: 2)
        for word in ["one ", "two ", "three ", "four ", "five ", "six"] {
            a.apply(SonioxResponse(tokens: [tok(word, final: true, en: true)]), at: t0)
        }
        XCTAssertEqual(a.frame(at: t0).english.map(\.text), ["three four", "five six"])
    }

    func testBufferIsTrimmedAtWordBoundary() {
        let long = String(repeating: "word ", count: 300)
        let trimmed = SubtitleAssembler.trimmed(long, limit: 600)
        XCTAssertLessThanOrEqual(trimmed.count, 600)
        XCTAssertTrue(trimmed.first?.isWhitespace ?? false)
    }
}

final class AudioTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let loud = [Int16](repeating: 8000, count: 1600)
    let quiet = [Int16](repeating: 0, count: 1600)

    func testLevel() {
        XCTAssertEqual(PCM.levelDB(quiet), -120)
        XCTAssertEqual(PCM.levelDB([Int16](repeating: 32767, count: 10)), 0, accuracy: 0.01)
        XCTAssertGreaterThan(PCM.levelDB(loud), -55)
    }

    func testLittleEndian() {
        XCTAssertEqual(PCM.littleEndianData([0x0102, -1]), Data([0x02, 0x01, 0xFF, 0xFF]))
        XCTAssertEqual(PCM.int16(1), 32767)
        XCTAssertEqual(PCM.int16(-2), -32767)
        XCTAssertEqual(PCM.int16(.nan), 0)
    }

    func testSilenceIsNotSent() {
        var p = AudioPipeline()
        XCTAssertEqual(p.append(quiet, at: t0), [])
        XCTAssertEqual(p.append(quiet, at: t0.addingTimeInterval(0.1)), [])
        XCTAssertFalse(p.isOpen)
    }

    func testGateOpensWithPrerollAndClosesWithFinalize() {
        var p = AudioPipeline(hangover: 1.0)
        _ = p.append(quiet, at: t0)
        let opened = p.append(loud, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(opened.count, 2, "preroll + loud chunk")
        XCTAssertTrue(p.isOpen)
        // Quiet within the hangover is still sent.
        XCTAssertEqual(p.append(quiet, at: t0.addingTimeInterval(0.6)).count, 1)
        // After the hangover: last chunk, then finalize, then nothing.
        let closing = p.append(quiet, at: t0.addingTimeInterval(1.2))
        XCTAssertEqual(closing.last, .finalize)
        XCTAssertEqual(closing.count, 2)
        XCTAssertFalse(p.isOpen)
        XCTAssertEqual(p.append(quiet, at: t0.addingTimeInterval(1.3)), [])
    }

    func testChunksSmallBuffers() {
        var p = AudioPipeline(chunkSamples: 1600)
        XCTAssertEqual(p.append(Array(loud.prefix(1000)), at: t0), [])
        let out = p.append(Array(loud.prefix(1000)), at: t0)
        guard case .audio(let data)? = out.first else { return XCTFail("expected audio") }
        XCTAssertEqual(data.count, 3200)
    }

    func testResamplerPassThroughAndMixdown() {
        var r = MonoResampler(targetRate: 16_000)
        XCTAssertEqual(r.process(channels: [[0.5, -0.5], [0.5, 0.5]], sourceRate: 16_000), [16384, 0])
    }

    func testResamplerDownsamplesContinuously() {
        var r = MonoResampler(targetRate: 16_000)
        var total = 0
        for _ in 0..<100 {  // 100 buffers of 480 samples at 48 kHz = 1 s
            total += r.process(channels: [[Float](repeating: 0.25, count: 480)], sourceRate: 48_000).count
        }
        XCTAssertEqual(total, 16_000, accuracy: 2)
        let one = r.process(channels: [[Float](repeating: 0.25, count: 480)], sourceRate: 48_000)
        XCTAssertTrue(one.allSatisfy { abs(Int($0) - 8192) <= 1 })
    }

    func testResamplerUpsamples() {
        var r = MonoResampler(targetRate: 16_000)
        var total = 0
        for _ in 0..<10 { total += r.process(channels: [[Float](repeating: 0.1, count: 800)], sourceRate: 8_000).count }
        XCTAssertEqual(total, 16_000, accuracy: 2)
    }
}
