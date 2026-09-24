import XCTest
@testable import TetherviewCore

final class PTPTests: XCTestCase {
    func testCommandContainerLayout() {
        let d = PTPContainer.command(opcode: 0x1007, transactionID: 7, params: [0x10000002, 0, 0])
        XCTAssertEqual([UInt8](d), [
            24, 0, 0, 0,            // length
            1, 0,                   // type = command
            0x07, 0x10,             // GetObjectHandles
            7, 0, 0, 0,             // transaction
            0x02, 0, 0, 0x10,       // storage 0x10000002
            0, 0, 0, 0,
            0, 0, 0, 0,
        ])
    }

    func testParseResponse() {
        var d = Data()
        d.appendLE(UInt32(16)); d.appendLE(UInt16(3)); d.appendLE(UInt16(0x2001))
        d.appendLE(UInt32(9)); d.appendLE(UInt32(0xABCD))
        let r = PTPContainer.parseResponse(d)
        XCTAssertEqual(r?.code, 0x2001)
        XCTAssertEqual(r?.params, [0xABCD])
        XCTAssertNil(PTPContainer.parseResponse(Data([1, 2, 3])))
    }

    func testStripDataHeader() {
        var full = Data()
        full.appendLE(UInt32(14)); full.appendLE(UInt16(2)); full.appendLE(UInt16(0x1015)); full.appendLE(UInt32(1))
        full.appendLE(UInt16(0x0002))
        XCTAssertEqual(PTPContainer.stripDataHeaderIfPresent(full).readLE16(at: 0), 2)
        let bare = Data([0x02, 0x00])
        XCTAssertEqual(PTPContainer.stripDataHeaderIfPresent(bare), bare)
    }

    func testUInt32Array() {
        var d = Data(); d.appendLE(UInt32(2)); d.appendLE(UInt32(5)); d.appendLE(UInt32(6))
        XCTAssertEqual(PTPContainer.parseUInt32Array(d), [5, 6])
        var lying = Data(); lying.appendLE(UInt32(1000)); lying.appendLE(UInt32(5))
        XCTAssertEqual(PTPContainer.parseUInt32Array(lying), [5])
        XCTAssertEqual(PTPContainer.parseUInt32Array(Data()), [])
    }

    func testJPEGExtract() {
        let d = Data([9, 9, 0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 0xFF, 0xD9, 0, 0])
        XCTAssertEqual([UInt8](JPEG.extract(from: d)!), [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 0xFF, 0xD9])
        XCTAssertNil(JPEG.extract(from: Data([1, 2, 3, 4, 5])))
    }

    func testDeviceInfoParse() {
        let raw = MockFujiCamera.buildDeviceInfo(model: "X-T50", ops: [0x1001, 0x101C], props: [0xD207])
        let info = PTPDeviceInfo.parse(raw)
        XCTAssertEqual(info?.model, "X-T50")
        XCTAssertEqual(info?.manufacturer, "FUJIFILM")
        XCTAssertEqual(info?.deviceVersion, "1.10")
        XCTAssertEqual(info?.vendorExtensionID, Fuji.vendorExtensionID)
        XCTAssertTrue(info?.supports(operation: 0x101C) ?? false)
        XCTAssertTrue(info?.supports(property: 0xD207) ?? false)
        XCTAssertNil(PTPDeviceInfo.parse(Data([1])))
    }
}

final class LiveViewTests: XCTestCase {
    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var statuses: [String] = []
        var logs: [String] = []
        func frame(_ d: Data) { lock.lock(); frames.append(d); lock.unlock() }
        func status(_ s: String) { lock.lock(); statuses.append(s); lock.unlock() }
        func log(_ s: String) { lock.lock(); logs.append(s); lock.unlock() }
        var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    }

    let fast = LiveViewOptions(framePollInterval: 0.001, idlePollInterval: 0.002,
                               firstCommandTimeout: 1, commandTimeout: 1)

    /// Runs live view until `frames` frames arrive (or a deadline), then cancels.
    func runLive(_ cam: MockFujiCamera, options: LiveViewOptions, frames: Int) async throws -> Collector {
        let c = Collector()
        let lv = FujiLiveView(transport: cam, log: { c.log($0) })
        let task = Task {
            try await lv.run(options: options,
                             onStatus: { c.status($0) },
                             onFrame: { c.frame($0) },
                             onStats: { _ in })
        }
        let deadline = Date().addingTimeInterval(5)
        while c.frameCount < frames && Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        task.cancel()
        _ = await task.result
        return c
    }

    func testStreamsWithoutTakingControl() async throws {
        let cam = MockFujiCamera()
        let c = try await runLive(cam, options: fast, frames: 5)
        XCTAssertGreaterThanOrEqual(c.frameCount, 5)
        XCTAssertEqual(c.frames.first?.first, 0xFF)       // header stripped
        XCTAssertEqual(cam.priorityWrites, [])            // never locked the camera
        XCTAssertEqual(cam.terminateCount, 1)             // stopped cleanly
        XCTAssertTrue(cam.liveHandles.isEmpty)            // no previews left behind
    }

    func testNeedsControlWhenNotAllowed() async throws {
        let cam = MockFujiCamera()
        cam.requiresControlToStream = true
        let lv = FujiLiveView(transport: cam, log: { _ in })
        do {
            try await lv.run(options: fast, onStatus: { _ in }, onFrame: { _ in }, onStats: { _ in })
            XCTFail("expected needsControl")
        } catch LiveViewFailure.needsControl(let code) {
            XCTAssertEqual(code, PTPResponse.fujiRefusedInThisState)
        }
        XCTAssertEqual(cam.priority, Fuji.priorityCamera)
    }

    func testTakesAndReturnsControlWhenAllowed() async throws {
        let cam = MockFujiCamera()
        cam.requiresControlToStream = true
        var opts = fast
        opts.allowTakeControl = true
        let c = try await runLive(cam, options: opts, frames: 3)
        XCTAssertGreaterThanOrEqual(c.frameCount, 3)
        XCTAssertEqual(cam.priorityWrites, [Fuji.priorityHost, Fuji.priorityCamera])
        XCTAssertEqual(cam.priority, Fuji.priorityCamera) // handed back after cancel
        XCTAssertEqual(cam.terminateCount, 1)
    }

    func testWrongUSBModeIsReported() async throws {
        let cam = MockFujiCamera()
        cam.tetherMode = false
        let lv = FujiLiveView(transport: cam, log: { _ in })
        do {
            try await lv.run(options: fast, onStatus: { _ in }, onFrame: { _ in }, onStats: { _ in })
            XCTFail("expected notInTetherMode")
        } catch LiveViewFailure.notInTetherMode(let model) {
            XCTAssertEqual(model, "X-T50")
        }
    }
}
