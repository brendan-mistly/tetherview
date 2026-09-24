import Foundation
import SwiftUI
import UIKit

/// Wi-Fi live view: Bluetooth handover → user joins the camera's Wi-Fi →
/// Fujifilm PTP/IP live view.
@MainActor
final class WiFiManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case bluetooth
        case joinWiFi(FujiWiFiCredentials)
        case connecting
        case live
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = ""
    @Published private(set) var frame: UIImage?
    @Published private(set) var fps: Double = 0
    @Published private(set) var cameraName: String?

    var log: @MainActor (String) -> Void = { _ in }

    private let ble = FujiBLE()
    private var task: Task<Void, Never>?
    private let decoder = FrameDecoder()
    private var generation = 0

    var isActive: Bool { phase != .idle }

    // MARK: - Actions

    /// Full flow: Bluetooth pairing and Wi-Fi request, then connect.
    func start() {
        stopTask()
        generation += 1
        let gen = generation
        phase = .bluetooth
        status = "Starting Bluetooth…"
        ble.log = { [weak self] in self?.log($0) }
        ble.onStatus = { [weak self] s in
            guard let self = self, self.generation == gen else { return }
            self.status = s
        }
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                let creds = try await self.ble.requestWiFi(clientName: "Tetherview")
                guard self.generation == gen else { return }
                UIPasteboard.general.string = creds.password
                self.phase = .joinWiFi(creds)
                self.status = "Join the camera's Wi-Fi"
                // Try right away in case the iPhone already knows this network.
                self.connect(retryFor: 8, quiet: true)
            } catch {
                guard self.generation == gen else { return }
                self.log("Bluetooth step failed: \(error)")
                self.phase = .failed("\(error)")
                self.status = "\(error)"
            }
        }
    }

    /// Skip Bluetooth: the iPhone is already on the camera's Wi-Fi (e.g. set
    /// up by Fujifilm's app).
    func connectNow() {
        connect(retryFor: 20, quiet: false)
    }

    /// Called when the app comes back to the foreground (e.g. from Settings).
    func appBecameActive() {
        if case .joinWiFi = phase {
            connect(retryFor: 45, quiet: false)
        }
    }

    func stop() {
        stopTask()
        ble.disconnect()
        phase = .idle
        status = ""
        frame = nil
        fps = 0
    }

    // MARK: - Wi-Fi live view

    private func connect(retryFor seconds: TimeInterval, quiet: Bool) {
        let previousPhase = phase
        stopTask()
        generation += 1
        let gen = generation
        if !quiet { phase = .connecting }
        status = "Connecting to the camera over Wi-Fi…"
        let decoder = self.decoder
        let logger: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }

        task = Task { [weak self] in
            let deadline = Date().addingTimeInterval(seconds)
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                let live = FujiWiFiLiveView(
                    clientName: "Tetherview",
                    open: { port in try await NWStream.connect(host: FujiIP.host, port: port, timeout: 6) },
                    log: logger)
                do {
                    try await live.run(
                        onStatus: { text in
                            Task { @MainActor in
                                guard let self = self, self.generation == gen else { return }
                                if text == "Live" {
                                    self.phase = .live
                                    self.status = "Live"
                                } else {
                                    self.phase = .connecting
                                    self.status = text
                                }
                            }
                        },
                        onFrame: { jpeg in
                            decoder.decode(jpeg) { image in
                                Task { @MainActor in
                                    guard let self = self, self.generation == gen else { return }
                                    self.frame = image
                                }
                            }
                        },
                        onStats: { fps in
                            Task { @MainActor in
                                guard let self = self, self.generation == gen else { return }
                                self.fps = fps
                            }
                        })
                    // run() only returns normally when cancelled.
                    return
                } catch is CancellationError {
                    return
                } catch FujiWiFiFailure.cannotReachCamera(let why) {
                    logger("Wi-Fi attempt \(attempt): camera not reachable (\(why))")
                    if Date() > deadline {
                        await MainActor.run {
                            guard let self = self, self.generation == gen else { return }
                            if quiet {
                                self.phase = previousPhase
                                self.status = "Join the camera's Wi-Fi"
                            } else {
                                self.phase = .failed("Can't reach the camera. Make sure the iPhone is connected to the camera's Wi-Fi network (Settings › Wi-Fi), then tap Connect.")
                                self.status = "Not connected"
                            }
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    logger("Wi-Fi live view stopped: \(error)")
                    await MainActor.run {
                        guard let self = self, self.generation == gen else { return }
                        self.phase = .failed("\(error)")
                        self.status = "\(error)"
                        self.fps = 0
                    }
                    return
                }
            }
        }
    }

    private func stopTask() {
        task?.cancel()
        task = nil
    }
}
