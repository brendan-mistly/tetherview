import XCTest
@testable import TetherviewCore

final class FujiWiFiTests: XCTestCase {
    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var statuses: [String] = []
        var logs: [String] = []
        func frame(_ d: Data) { lock.lock(); frames.append(d); lock.unlock() }
        func status(_ s: String) { lock.lock(); statuses.append(s); lock.unlock() }
        func log(_ s: String) { lock.lock(); logs.append(s); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    }

    func testEventParsing() {
        var d = Data()
        d.appendLE(UInt16(2))
        d.appendLE(UInt16(0xDF00)); d.appendLE(UInt32(6))
        d.appendLE(UInt16(0xD222)); d.appendLE(UInt32(42))
        XCTAssertEqual(FujiWiFiLiveView.parseEvents(d),
                       [FujiEvent(code: 0xDF00, value: 6), FujiEvent(code: 0xD222, value: 42)])
        XCTAssertEqual(FujiWiFiLiveView.parseEvents(Data([5, 0, 1])), [])
    }

    func testHandshakePacketLayout() async throws {
        let (client, server) = MemoryStream.pair()
        let t = FujiIPTransport(stream: client, log: { _ in })
        let task = Task { try await t.handshake(clientName: "Tetherview", timeout: 2) }
        let p = try await server.receive(exactly: 0x52, timeout: 2)
        XCTAssertEqual(p.readLE32(at: 0), 0x52)
        XCTAssertEqual(p.readLE32(at: 4), 1)
        XCTAssertEqual(p.readLE32(at: 8), 0x8F53E4F2)
        XCTAssertEqual(p.readLE32(at: 12), 0x5D48A5AD)
        XCTAssertEqual(p.readLE32(at: 16), 0x0B7FB287)
        XCTAssertEqual(p.readLE32(at: 20), 0xD0DED5D3)
        XCTAssertEqual(p.readLE16(at: 28), UInt16(UInt8(ascii: "T")))
        var ack = Data(); ack.appendLE(UInt32(0x44)); ack.appendLE(UInt32(2))
        for _ in 0..<5 { ack.appendLE(UInt32(0)) }
        for u in "X-T50".utf16 { ack.appendLE(u) }
        ack.append(Data(count: 0x44 - ack.count))
        try await server.send(ack)
        let name = try await task.value
        XCTAssertEqual(name, "X-T50")
    }

    func testFullLiveViewFlow() async throws {
        let cam = MockFujiWiFiCamera()
        let c = Collector()
        let lv = FujiWiFiLiveView(open: cam.opener, log: { c.log($0) })
        let task = Task {
            try await lv.run(onStatus: { c.status($0) }, onFrame: { c.frame($0) }, onStats: { _ in })
        }
        let deadline = Date().addingTimeInterval(8)
        while c.count < 5 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        _ = await task.result
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertGreaterThanOrEqual(c.count, 5, "logs: \(c.logs)")
        XCTAssertEqual(c.frames.first?.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(cam.sessionOpenedWithTx, 1)
        let clientWrites = cam.propWrites.filter { $0.0 == FujiIP.clientState }.map { $0.1.readLE16(at: 0) }
        XCTAssertEqual(clientWrites, [FujiIP.clientXAppGallery, FujiIP.clientXAppLiveView])
        XCTAssertEqual(cam.terminatedTx, cam.initiateTx)
        XCTAssertTrue(cam.gotGoodbye)
        XCTAssertTrue(c.statuses.contains("Live"))
    }

    func testRefusedInitIsReported() async throws {
        let cam = MockFujiWiFiCamera()
        cam.refuseInit = true
        let lv = FujiWiFiLiveView(open: cam.opener, log: { _ in })
        do {
            try await lv.run(onStatus: { _ in }, onFrame: { _ in }, onStats: { _ in })
            XCTFail("expected failure")
        } catch FujiWiFiFailure.refused(let why) {
            XCTAssertTrue(why.contains("refused"), why)
        }
    }

    func testUnreachableCamera() async throws {
        let lv = FujiWiFiLiveView(open: { _ in throw PTPError("no route") }, log: { _ in })
        do {
            try await lv.run(onStatus: { _ in }, onFrame: { _ in }, onStats: { _ in })
            XCTFail("expected failure")
        } catch FujiWiFiFailure.cannotReachCamera {
        }
    }
}
