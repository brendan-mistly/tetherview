// PTP over USB on iPhone, via Apple's ImageCaptureCore.
//
// iOS will not hand the camera's webcam (UVC) stream to apps on iPhone, but it
// DOES let apps talk PTP — the protocol cameras use for tethered shooting — to
// a camera plugged into the USB-C port. That is the whole trick this app
// relies on.
//
// Implementation notes borrowed from people who have fought this API on
// iOS 26 (see che/nikon_ptp_flutter, and Cascable's approach it documents):
//  * Use the selector-based requestSendPTPCommand, not the block one.
//  * Ask only for *control* authorization, never contents.
//  * The first command after opening a session can be held by iOS for a
//    long time (tens of seconds) while it indexes the camera's card.

import Foundation
import ImageCaptureCore

/// A PTP transport bound to one open ImageCaptureCore camera session.
final class ICCTransport: NSObject, PTPTransport, @unchecked Sendable {
    private let camera: ICCameraDevice
    private let log: @Sendable (String) -> Void

    // Main-thread state.
    private var transactionID: UInt32 = 1
    private var pending: [String: Pending] = [:]

    private final class Pending {
        let opcode: UInt16
        let started = Date()
        var continuation: CheckedContinuation<PTPResult, Error>?
        init(opcode: UInt16, continuation: CheckedContinuation<PTPResult, Error>) {
            self.opcode = opcode
            self.continuation = continuation
        }
    }

    init(camera: ICCameraDevice, log: @escaping @Sendable (String) -> Void) {
        self.camera = camera
        self.log = log
    }

    func send(_ opcode: UInt16, params: [UInt32], outData: Data?, timeout: TimeInterval) async throws -> PTPResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PTPResult, Error>) in
            DispatchQueue.main.async {
                self.sendOnMain(opcode, params: params, outData: outData, timeout: timeout, continuation: cont)
            }
        }
    }

    /// Fails every in-flight command, e.g. when the camera is unplugged.
    func failAll(_ reason: String) {
        DispatchQueue.main.async {
            let all = self.pending
            self.pending.removeAll()
            for (_, p) in all {
                p.continuation?.resume(throwing: PTPError(reason))
                p.continuation = nil
            }
        }
    }

    private func sendOnMain(_ opcode: UInt16, params: [UInt32], outData: Data?, timeout: TimeInterval,
                            continuation: CheckedContinuation<PTPResult, Error>) {
        guard camera.hasOpenSession else {
            continuation.resume(throwing: PTPError("No open session with the camera"))
            return
        }
        let tx = transactionID
        transactionID &+= 1
        let command = PTPContainer.command(opcode: opcode, transactionID: tx, params: params)

        let key = UUID().uuidString
        pending[key] = Pending(opcode: opcode, continuation: continuation)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, let p = self.pending.removeValue(forKey: key) else { return }
            self.log(String(format: "PTP 0x%04X timed out after %.0fs", opcode, timeout))
            p.continuation?.resume(throwing: PTPError(String(format: "Camera did not answer (0x%04X)", opcode)))
            p.continuation = nil
        }

        let ctx = Unmanaged.passRetained(key as NSString).toOpaque()
        camera.requestSendPTPCommand(
            command,
            outData: outData,
            sendCommandDelegate: self,
            didSendCommand: #selector(didSendPTPCommand(_:inData:response:error:contextInfo:)),
            contextInfo: ctx
        )
    }

    @objc private func didSendPTPCommand(_ command: NSData,
                                         inData: NSData?,
                                         response: NSData?,
                                         error: NSError?,
                                         contextInfo: UnsafeMutableRawPointer?) {
        guard let ctx = contextInfo else { return }
        // Balance the passRetained in sendOnMain exactly once, whatever happens.
        let key = Unmanaged<NSString>.fromOpaque(ctx).takeRetainedValue() as String
        let inBytes = inData as Data?
        let responseBytes = response as Data?
        // ImageCaptureCore calls back on the main thread; hop there if it ever doesn't.
        if Thread.isMainThread {
            finish(key: key, inData: inBytes, response: responseBytes, error: error)
        } else {
            DispatchQueue.main.async {
                self.finish(key: key, inData: inBytes, response: responseBytes, error: error)
            }
        }
    }

    private func finish(key: String, inData: Data?, response: Data?, error: NSError?) {
        guard let p = pending.removeValue(forKey: key), let cont = p.continuation else { return }
        p.continuation = nil
        let ms = Int(Date().timeIntervalSince(p.started) * 1000)
        if ms > 3000 {
            log(String(format: "PTP 0x%04X took %d ms", p.opcode, ms))
        }
        if let error = error {
            log(String(format: "PTP 0x%04X error %@ %ld: %@", p.opcode, error.domain, error.code,
                       error.localizedDescription))
            cont.resume(throwing: PTPError("\(error.localizedDescription) (\(error.code))"))
            return
        }
        guard let parsed = PTPContainer.parseResponse(response) else {
            cont.resume(returning: PTPResult(code: PTPResponse.generalError))
            return
        }
        let data = PTPContainer.stripDataHeaderIfPresent(inData ?? Data())
        cont.resume(returning: PTPResult(code: parsed.code, params: parsed.params, data: data))
    }
}
