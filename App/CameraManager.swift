import Foundation
import ImageCaptureCore
import SwiftUI
import UIKit

/// Finds the camera on the USB-C port, opens a session and runs live view.
@MainActor
final class CameraManager: NSObject, ObservableObject {
    enum Phase: Equatable {
        case waitingForCamera
        case connecting
        case live
        case needsControl
        case failed(String)
    }

    @Published private(set) var phase: Phase = .waitingForCamera
    @Published private(set) var status = "Plug the camera into the iPhone"
    @Published private(set) var cameraName: String?
    @Published private(set) var frame: UIImage?
    @Published private(set) var fps: Double = 0
    @Published private(set) var hasControl = false
    @Published private(set) var logLines: [String] = []

    @AppStorage("allowTakeControl") var allowTakeControl = false

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var transport: ICCTransport?
    private var liveTask: Task<Void, Never>?
    /// Bumped whenever a live session is superseded or abandoned, so a stale
    /// session's ending can't overwrite the current phase.
    private var liveGeneration = 0
    private var stopBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var started = false
    private let decoder = FrameDecoder()

    override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        log("Tetherview \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") on iOS \(UIDevice.current.systemVersion)")
        browser.delegate = self
        if let mask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue) {
            browser.browsedDeviceTypeMask = mask
        }
        // Available since iOS 14 (the deployment target is 17), so always ask.
        browser.requestControlAuthorization { [weak self] status in
            Task { @MainActor in self?.log("Camera control permission: \(status.rawValue)") }
        }
        browser.start()
        log("Looking for a camera on USB")
    }

    /// Stop live view and hand the camera back (used when the app backgrounds).
    func suspend() {
        guard let task = liveTask, !task.isCancelled else { return }
        task.cancel()
        // Ask iOS for time to send TerminateOpenCapture and hand the camera's
        // controls back before the app is suspended.
        endStopBackgroundTask()
        let id = UIApplication.shared.beginBackgroundTask(withName: "Stop live view") { [weak self] in
            MainActor.assumeIsolated { self?.endStopBackgroundTask() }
        }
        stopBackgroundTask = id
        Task { [weak self] in
            await task.value
            self?.endStopBackgroundTask(id)
        }
    }

    /// Ends the pending background task (only if it is `id`, when given).
    private func endStopBackgroundTask(_ id: UIBackgroundTaskIdentifier? = nil) {
        guard stopBackgroundTask != .invalid, id == nil || id == stopBackgroundTask else { return }
        UIApplication.shared.endBackgroundTask(stopBackgroundTask)
        stopBackgroundTask = .invalid
    }

    func resume() {
        guard liveTask == nil || liveTask?.isCancelled == true else { return }
        if let camera = camera, camera.hasOpenSession {
            startLiveView()
        }
    }

    func retry() {
        // Keep liveTask: startLiveView() waits for it to finish stopping.
        liveTask?.cancel()
        if let camera = camera {
            if camera.hasOpenSession {
                startLiveView()
            } else {
                open(camera)
            }
        } else {
            setPhase(.waitingForCamera, "Plug the camera into the iPhone")
        }
    }

    func grantControlAndRetry() {
        allowTakeControl = true
        retry()
    }

    // MARK: - Session

    private func open(_ camera: ICCameraDevice) {
        if self.camera !== camera { transport = nil }
        self.camera = camera
        cameraName = camera.name
        camera.delegate = self
        setPhase(.connecting, "Opening \(camera.name ?? "camera")…")
        log("Opening session with \(camera.name ?? "camera")")
        camera.requestOpenSession()
    }

    private func startLiveView() {
        guard let camera = camera else { return }
        let previous = liveTask
        previous?.cancel()
        liveGeneration += 1
        let generation = liveGeneration
        // One transport per camera session, so PTP transaction IDs keep counting up.
        let transport = self.transport ?? ICCTransport(camera: camera, log: { [weak self] line in
            Task { @MainActor in self?.log(line) }
        })
        self.transport = transport
        let options = LiveViewOptions(allowTakeControl: allowTakeControl)
        let live = FujiLiveView(transport: transport, log: { [weak self] line in
            Task { @MainActor in self?.log(line) }
        })
        let decoder = self.decoder
        setPhase(.connecting, "Starting live view…")

        liveTask = Task { [weak self] in
            // Let the previous session finish stopping (TerminateOpenCapture,
            // hand control back) so it can't kill the stream we're starting.
            await previous?.value
            do {
                try await live.run(
                    options: options,
                    onStatus: { text in
                        Task { @MainActor in
                            guard let self = self, self.liveGeneration == generation else { return }
                            if text == "Live" {
                                self.setPhase(.live, "Live")
                            } else {
                                self.status = text
                            }
                        }
                    },
                    onFrame: { jpeg in
                        decoder.decode(jpeg) { image in
                            Task { @MainActor in
                                guard let self = self, self.liveGeneration == generation else { return }
                                self.frame = image
                            }
                        }
                    },
                    onStats: { stats in
                        Task { @MainActor in
                            guard let self = self, self.liveGeneration == generation else { return }
                            self.fps = stats.framesPerSecond
                            self.hasControl = stats.tookControl
                        }
                    })
                await MainActor.run { self?.liveEnded(error: nil, generation: generation) }
            } catch {
                await MainActor.run { self?.liveEnded(error: error, generation: generation) }
            }
        }
    }

    private func liveEnded(error: Error?, generation: Int) {
        let isCurrent = generation == liveGeneration
        if isCurrent {
            hasControl = false
            fps = 0
        }
        guard let error = error, !(error is CancellationError) else {
            log("Live view stopped")
            return
        }
        guard isCurrent else {
            // Superseded (retry) or abandoned (camera unplugged): just log it.
            log("Previous live view ended: \(error)")
            return
        }
        if case LiveViewFailure.needsControl = error {
            log("\(error)")
            setPhase(.needsControl, "The camera will only stream if the app takes control")
            return
        }
        log("Stopped: \(error)")
        setPhase(.failed("\(error)"), "\(error)")
    }

    private func cameraGone() {
        log("Camera disconnected")
        liveGeneration += 1
        liveTask?.cancel()
        liveTask = nil
        transport?.failAll("Camera disconnected")
        transport = nil
        camera = nil
        cameraName = nil
        frame = nil
        fps = 0
        hasControl = false
        setPhase(.waitingForCamera, "Plug the camera into the iPhone")
    }

    // MARK: - Helpers

    private func setPhase(_ p: Phase, _ text: String) {
        phase = p
        status = text
    }

    func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        logLines.append("\(f.string(from: Date()))  \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }
}

// MARK: - ImageCaptureCore delegates

extension CameraManager: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard let cam = device as? ICCameraDevice else { return }
            self.log("Found \(cam.name ?? "a camera")")
            if self.camera == nil {
                self.open(cam)
            }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            if device === self.camera { self.cameraGone() }
        }
    }
}

extension CameraManager: ICCameraDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            if device === self.camera { self.cameraGone() }
        }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.log("Open session failed: \(error.localizedDescription)")
                self.setPhase(.failed(error.localizedDescription), "Couldn't open the camera: \(error.localizedDescription)")
                return
            }
            self.log("Session open")
            self.startLiveView()
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor in self.log("Session closed") }
    }

    nonisolated func device(_ device: ICDevice, didEncounterError error: Error?) {
        Task { @MainActor in self.log("Device error: \(error?.localizedDescription ?? "unknown")") }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                                  for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                  for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.log("Camera catalog ready") }
    }
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.log("Camera reports access restriction (locked?)") }
    }
}

/// Decodes JPEG frames off the main thread, dropping frames while busy so the
/// display never lags behind the camera.
final class FrameDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tetherview.decode", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false

    func decode(_ jpeg: Data, completion: @escaping @Sendable (UIImage) -> Void) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async {
            defer {
                self.lock.lock(); self.busy = false; self.lock.unlock()
            }
            guard let image = UIImage(data: jpeg) else { return }
            completion(image.preparingForDisplay() ?? image)
        }
    }
}
