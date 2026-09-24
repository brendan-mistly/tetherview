// Fujifilm USB live view over PTP.
//
// Protocol notes (from mikefsq/ptp, MIT, tested on an X-T5; the X-T50 uses the
// same X-Processor 5 generation):
//   * The body must be in USB TETHER SHOOTING (AUTO or FIXED) mode.
//   * InitiateOpenCapture(0, 0) starts the preview stream.
//   * Preview frames appear as objects in storage 0x10000002. Fetch the newest
//     with GetObject, then DeleteObject every handle — if previews pile up the
//     camera stops answering.
//   * Polling faster than the camera refreshes can also make it stop
//     answering, so back off when there is nothing new.
//   * TerminateOpenCapture(0) stops the stream.
//   * Property 0xD207 (priority) = 2 gives the host control and LOCKS the
//     body's dials and buttons; = 1 hands it back. Some bodies refuse to
//     stream without it, so it is only taken if the user allows it, and it is
//     always handed back on the way out.

import Foundation

public enum Fuji {
    public static let liveStore: UInt32 = 0x10000002
    public static let stillStore: UInt32 = 0x10000001
    public static let propPriorityMode: UInt32 = 0xD207
    public static let priorityCamera: UInt16 = 0x0001
    public static let priorityHost: UInt16 = 0x0002
    public static let vendorExtensionID: UInt32 = 0x0000000E
}

public struct LiveViewOptions: Sendable {
    /// Allow the app to take host priority if the camera will not stream
    /// without it. While held, the camera's own dials and buttons are locked.
    public var allowTakeControl: Bool
    /// Wait this long between polls after a new frame.
    public var framePollInterval: TimeInterval
    /// Wait this long when the camera had nothing new.
    public var idlePollInterval: TimeInterval
    /// Timeout for the very first command. iOS may hold it while it indexes
    /// the camera's storage, which has been measured at over a minute.
    public var firstCommandTimeout: TimeInterval
    public var commandTimeout: TimeInterval

    public init(allowTakeControl: Bool = false,
                framePollInterval: TimeInterval = 0.03,
                idlePollInterval: TimeInterval = 0.1,
                firstCommandTimeout: TimeInterval = 150,
                commandTimeout: TimeInterval = 10) {
        self.allowTakeControl = allowTakeControl
        self.framePollInterval = framePollInterval
        self.idlePollInterval = idlePollInterval
        self.firstCommandTimeout = firstCommandTimeout
        self.commandTimeout = commandTimeout
    }
}

public enum LiveViewFailure: Error, CustomStringConvertible, Sendable {
    /// Camera refused to stream unless the app takes control of it.
    case needsControl(code: UInt16)
    /// Camera does not offer remote capture — almost always the wrong USB mode.
    case notInTetherMode(model: String)
    case startRefused(code: UInt16)
    case lostCamera(String)

    public var description: String {
        switch self {
        case .needsControl(let c):
            return "The camera only streams if the app takes control (\(PTPResponse.name(c)))."
        case .notInTetherMode(let model):
            let name = model.isEmpty ? "The camera" : model
            return "\(name) isn't in tether mode. On the camera: MENU > NETWORK/USB SETTING > USB > USB TETHER SHOOTING AUTO, then replug."
        case .startRefused(let c):
            return "The camera refused to start live view (\(PTPResponse.name(c))). Close any menu or playback on the camera and half-press the shutter, then try again."
        case .lostCamera(let why):
            return "Lost the camera: \(why)"
        }
    }
}

public struct LiveViewStats: Sendable {
    public var framesPerSecond: Double
    public var lastFrameBytes: Int
    public var tookControl: Bool
}

public final class FujiLiveView: @unchecked Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let transport: PTPTransport
    private let log: Log

    public init(transport: PTPTransport, log: @escaping Log) {
        self.transport = transport
        self.log = log
    }

    /// Streams until the surrounding task is cancelled or the camera is lost.
    /// Always stops live view and hands control back before returning.
    public func run(options: LiveViewOptions,
                    onStatus: @escaping @Sendable (String) -> Void,
                    onFrame: @escaping @Sendable (Data) -> Void,
                    onStats: @escaping @Sendable (LiveViewStats) -> Void) async throws {
        onStatus("Talking to the camera… (the first connection can take up to a minute while iOS reads the camera)")
        let infoResult = try await transport.send(PTPOp.getDeviceInfo, params: [], outData: nil,
                                                  timeout: options.firstCommandTimeout)
        let info = PTPDeviceInfo.parse(PTPContainer.stripDataHeaderIfPresent(infoResult.data))
        if let info = info {
            log("DeviceInfo: \(info.manufacturer) \(info.model) fw \(info.deviceVersion); vendor 0x\(String(info.vendorExtensionID, radix: 16)); \(info.operations.count) ops, \(info.properties.count) props")
            log("Ops: " + info.operations.map { String(format: "%04X", $0) }.joined(separator: " "))
            if !info.operations.isEmpty && !info.supports(operation: PTPOp.initiateOpenCapture) {
                throw LiveViewFailure.notInTetherMode(model: info.model)
            }
        } else {
            log("DeviceInfo could not be parsed (\(infoResult.data.count) bytes, response \(PTPResponse.name(infoResult.code)))")
        }

        // Don't start streaming if we were cancelled while iOS held the first
        // command (that can take a minute).
        try Task.checkCancellation()

        var tookControl = false
        do {
            try await start(options: options, onStatus: onStatus, tookControl: &tookControl)
            onStatus("Live")
            try await pollLoop(options: options, tookControl: tookControl,
                               onStatus: onStatus, onFrame: onFrame, onStats: onStats)
        } catch {
            await stop(tookControl: tookControl, options: options)
            throw error
        }
        await stop(tookControl: tookControl, options: options)
    }

    // MARK: - Start / stop

    /// Sets `tookControl` as soon as host priority may have been taken, so the
    /// caller hands it back even if a later step throws.
    private func start(options: LiveViewOptions, onStatus: @Sendable (String) -> Void,
                       tookControl: inout Bool) async throws {
        // First try without touching priority, so the camera stays usable.
        var code = try await initiate(options: options)
        if code == PTPResponse.ok {
            log("Live view started without taking control — camera controls stay live")
            return
        }
        log("InitiateOpenCapture without control: \(PTPResponse.name(code))")

        guard options.allowTakeControl else {
            throw LiveViewFailure.needsControl(code: code)
        }

        onStatus("Taking control of the camera…")
        tookControl = true
        try await setPriority(Fuji.priorityHost, options: options)
        code = try await initiate(options: options)
        guard code == PTPResponse.ok else {
            try? await setPriority(Fuji.priorityCamera, options: options)
            tookControl = false
            throw LiveViewFailure.startRefused(code: code)
        }
        log("Live view started with host control — camera dials are locked while connected")
    }

    /// InitiateOpenCapture with a few retries for "busy right now" answers.
    private func initiate(options: LiveViewOptions) async throws -> UInt16 {
        var last = PTPResponse.generalError
        for attempt in 0..<6 {
            let r = try await transport.send(PTPOp.initiateOpenCapture, params: [0, 0], outData: nil,
                                             timeout: options.commandTimeout)
            last = r.code
            if r.isOK { return r.code }
            if r.code == PTPResponse.deviceBusy || r.code == PTPResponse.fujiRefusedRightNow {
                log("InitiateOpenCapture busy (\(PTPResponse.name(r.code))), retry \(attempt + 1)")
                try await sleep(0.3)
                continue
            }
            return r.code
        }
        return last
    }

    private func setPriority(_ value: UInt16, options: LiveViewOptions) async throws {
        // Skip redundant writes: an X-T5 answers them with 0xA002.
        let current = try await transport.send(PTPOp.getDevicePropValue, params: [Fuji.propPriorityMode],
                                               outData: nil, timeout: options.commandTimeout)
        if current.isOK, PTPContainer.stripDataHeaderIfPresent(current.data).readLE16(at: 0) == value {
            return
        }
        var payload = Data()
        payload.appendLE(value)
        let deadline = Date().addingTimeInterval(value == Fuji.priorityCamera ? 10 : 3)
        while true {
            let r = try await transport.send(PTPOp.setDevicePropValue, params: [Fuji.propPriorityMode],
                                             outData: payload, timeout: options.commandTimeout)
            if r.isOK {
                log("Priority set to \(value == Fuji.priorityHost ? "app" : "camera")")
                return
            }
            if Date() > deadline {
                throw PTPError("Camera refused priority change (\(PTPResponse.name(r.code)))")
            }
            try await sleep(0.25)
        }
    }

    private func stop(tookControl: Bool, options: LiveViewOptions) async {
        // Usually runs because the task was cancelled. Do the cleanup in a
        // fresh, uncancelled task so its sleeps and retries still work.
        await Task.detached { [self] in
            await self.stopNow(tookControl: tookControl, options: options)
        }.value
    }

    private func stopNow(tookControl: Bool, options: LiveViewOptions) async {
        let r = try? await transport.send(PTPOp.terminateOpenCapture, params: [0], outData: nil,
                                          timeout: options.commandTimeout)
        log("TerminateOpenCapture: \(r.map { PTPResponse.name($0.code) } ?? "no answer")")
        if tookControl {
            do {
                try await setPriority(Fuji.priorityCamera, options: options)
            } catch {
                log("Could not hand control back: \(error). Turn the camera off and on to unlock it.")
            }
        }
    }

    // MARK: - Frames

    private func pollLoop(options: LiveViewOptions,
                          tookControl: Bool,
                          onStatus: @Sendable (String) -> Void,
                          onFrame: @Sendable (Data) -> Void,
                          onStats: @Sendable (LiveViewStats) -> Void) async throws {
        var lastFrame = Data()
        var consecutiveErrors = 0
        var lastNewFrameAt = Date()
        var stalledReported = false
        var windowStart = Date()
        var windowFrames = 0

        while !Task.isCancelled {
            let handlesResult = try await transport.send(PTPOp.getObjectHandles,
                                                         params: [Fuji.liveStore, 0, 0],
                                                         outData: nil, timeout: options.commandTimeout)
            guard handlesResult.isOK else {
                consecutiveErrors += 1
                if consecutiveErrors == 1 || consecutiveErrors % 20 == 0 {
                    log("GetObjectHandles: \(PTPResponse.name(handlesResult.code)) (x\(consecutiveErrors))")
                }
                if consecutiveErrors >= 150 {
                    throw LiveViewFailure.lostCamera("the camera stopped sending frames (\(PTPResponse.name(handlesResult.code)))")
                }
                if handlesResult.code == PTPResponse.fujiRefusedInThisState {
                    onStatus("Paused — the camera is showing a menu or playback")
                }
                try await sleep(options.idlePollInterval * 2)
                continue
            }
            consecutiveErrors = 0

            let handles = PTPContainer.parseUInt32Array(PTPContainer.stripDataHeaderIfPresent(handlesResult.data))
            if let newest = handles.last {
                let obj = try await transport.send(PTPOp.getObject, params: [newest], outData: nil,
                                                   timeout: options.commandTimeout)
                // Consume every preview, newest included, so they never pile up.
                for h in handles {
                    _ = try? await transport.send(PTPOp.deleteObject, params: [h, 0], outData: nil,
                                                  timeout: options.commandTimeout)
                }
                if obj.isOK, let jpeg = JPEG.extract(from: obj.data), jpeg != lastFrame {
                    lastFrame = jpeg
                    onFrame(jpeg)
                    windowFrames += 1
                    lastNewFrameAt = Date()
                    if stalledReported {
                        stalledReported = false
                        onStatus("Live")
                    }
                    try await sleep(options.framePollInterval)
                } else {
                    if !obj.isOK { log("GetObject: \(PTPResponse.name(obj.code))") }
                    try await sleep(options.idlePollInterval)
                }
            } else {
                try await sleep(options.idlePollInterval)
            }

            let now = Date()
            if !stalledReported, now.timeIntervalSince(lastNewFrameAt) > 4 {
                stalledReported = true
                onStatus("No new frames — if the camera is showing a menu or playback, half-press the shutter")
            }
            let elapsed = now.timeIntervalSince(windowStart)
            if elapsed >= 1 {
                onStats(LiveViewStats(framesPerSecond: Double(windowFrames) / elapsed,
                                      lastFrameBytes: lastFrame.count,
                                      tookControl: tookControl))
                windowStart = now
                windowFrames = 0
            }
        }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
