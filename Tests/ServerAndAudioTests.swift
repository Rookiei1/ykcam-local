import XCTest
@testable import YKCam

final class ServerAndAudioTests: XCTestCase {
    func testNormalizeBaseURL() {
        XCTAssertEqual(ServerAPI.normalizeBaseURL("https://example.com/")?.absoluteString, "https://example.com")
        XCTAssertEqual(ServerAPI.normalizeBaseURL("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(ServerAPI.normalizeBaseURL("  http://127.0.0.1:3010/ ")?.absoluteString, "http://127.0.0.1:3010")
        XCTAssertNil(ServerAPI.normalizeBaseURL(""))
        XCTAssertNil(ServerAPI.normalizeBaseURL("   "))
        XCTAssertNil(ServerAPI.normalizeBaseURL("ftp://example.com"))
    }

    func testWebSocketURL() {
        let httpsBase = ServerAPI.normalizeBaseURL("https://example.com")!
        XCTAssertEqual(ServerAPI.webSocketURL(from: httpsBase)?.absoluteString, "wss://example.com/ws/agent")
        let httpBase = ServerAPI.normalizeBaseURL("http://127.0.0.1:3010")!
        XCTAssertEqual(ServerAPI.webSocketURL(from: httpBase)?.absoluteString, "ws://127.0.0.1:3010/ws/agent")
    }

    func testULawEncodingMatchesDecoderExpectation() {
        // Silence (0) maps to 0xFF
        XCTAssertEqual(LiveAudio.ulaw(0), 0xFF)
        // Negative peak maps to 0x00, positive peak maps to 0x80
        XCTAssertEqual(LiveAudio.ulaw(-32635), 0x00)
        XCTAssertEqual(LiveAudio.ulaw(Int16.min), 0x00)
        XCTAssertEqual(LiveAudio.ulaw(32635), 0x80)
        // Sign bit (0x80) is 1 for >= 0 and 0 for < 0 in G.711 inverted format
        XCTAssertEqual(LiveAudio.ulaw(1000) & 0x80, 0x80)
        XCTAssertEqual(LiveAudio.ulaw(-1000) & 0x80, 0x00)
    }
}
