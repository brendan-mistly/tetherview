// Fujifilm Bluetooth LE: pair with the camera and ask it to switch on its
// Wi-Fi, reading back the network name and password.
//
// Sequence from libfuji's bluetooth.c (MIT; derived from gkoh/furble), which
// handles both the "secure" pairing used by current firmware and the older
// token-based pairing. Every step is logged so a failed attempt on a new body
// still tells us exactly where it stopped.

import CoreBluetooth
import Foundation

struct FujiWiFiCredentials: Equatable {
    var ssid: String
    var password: String
}

enum FujiBLEUUID {
    static let securePairService = CBUUID(string: "123d8f06-62a1-4935-9322-833c531ee225")
    static let secureStatus = CBUUID(string: "f557d96b-8284-4667-8793-b971c1deca2a")
    static let legacyPairService = CBUUID(string: "91f1de68-dff6-466e-8b65-ff13b0f16fb8")
    static let legacyPairToken = CBUUID(string: "aba356eb-9633-4e60-b73f-f52516dbd671")
    static let clientName = CBUUID(string: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")

    static let wifiService = CBUUID(string: "4e941240-d01d-46b9-a5ea-67636806830b")
    static let wifiSSID = CBUUID(string: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")
    static let wifiPassword = CBUUID(string: "e809256a-915c-4967-92e8-53b7d4cad213")

    static let shutterService = CBUUID(string: "6514eb81-4e8f-458d-aa2a-e691336cdfac")
    static let wifiRequest = CBUUID(string: "600655e6-3637-42f1-8fb2-44efc5c63b13")

    static let confService = CBUUID(string: "4c0020fe-f3b6-40de-acc9-77d129067b14")
    static let apReadyIndication = CBUUID(string: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")

    /// Advertised when a camera is in pairing mode / reconnecting.
    static let advertised: [CBUUID] = [
        CBUUID(string: "a9d2b304-e8d6-4902-8336-352b772d7597"),
        securePairService,
        CBUUID(string: "117c4142-edd4-4c77-8696-dd18eebb770a"),
        CBUUID(string: "af854c2e-b214-458e-97e2-912c4ecf2cb8"),
    ]

    /// Characteristics libfuji subscribes to after pairing: (service, char).
    static let subscriptions: [(String, String)] = [
        ("4c0020fe-f3b6-40de-acc9-77d129067b14", "a68e3f66-0fcc-4395-8d4c-aa980b5877fa"),
        ("4c0020fe-f3b6-40de-acc9-77d129067b14", "bd17ba04-b76b-4892-a545-b73ba1f74dae"),
        ("4c0020fe-f3b6-40de-acc9-77d129067b14", "f9150137-5d40-4801-a8dc-f7fc5b01da50"),
        ("4c0020fe-f3b6-40de-acc9-77d129067b14", "ad06c7b7-f41a-46f4-a29a-712055319122"),
        ("804daa8e-ffeb-4ab3-8e75-6edd7303208d", "7170fd5a-56d9-4c19-b043-7a7047d8e1a0"),
        ("4e941240-d01d-46b9-a5ea-67636806830b", "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4"),
        ("4e941240-d01d-46b9-a5ea-67636806830b", "75823784-fbb7-4b71-abae-cd9a34072e3c"),
        ("4c0020fe-f3b6-40de-acc9-77d129067b14", "e6692c5c-b7cd-44f4-95fc-eda07ce32560"),
        ("4e941240-d01d-46b9-a5ea-67636806830b", "aab609c4-94dd-4d89-bc60-665d5090b828"),
        ("4e941240-d01d-46b9-a5ea-67636806830b", "2a125640-706d-4dd1-b420-c0f4ab93c361"),
        ("4e941240-d01d-46b9-a5ea-67636806830b", "82a9f452-c5ce-4ef5-8203-3fc9a47f8171"),
        ("4e941240-d01d-46b9-a5ea-67636806830b", "deef7187-3f43-4364-9e22-11a8c8a15951"),
        ("4e941240-d01d-46b9-a5ea-67636806830b", "c95d91ae-b247-4d6d-8661-7dd5d6a0f85b"),
        ("4c0020fe-f3b6-40de-acc9-77d129067b14", "049ec406-ef75-4205-a390-08fe209c51f0"),
    ]
}

@MainActor
final class FujiBLE: NSObject {
    var log: @MainActor (String) -> Void = { _ in }
    var onStatus: @MainActor (String) -> Void = { _ in }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var legacyToken: Data?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    private var poweredOn: CheckedContinuation<Void, Error>?
    private var found: CheckedContinuation<CBPeripheral, Error>?
    private var connected: CheckedContinuation<Void, Error>?
    private var servicesLeft = 0
    private var discovered: CheckedContinuation<Void, Error>?
    private var reads: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writes: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var apReady: CheckedContinuation<UInt8, Never>?
    private var seen = Set<UUID>()

    private static let savedPeripheralKey = "fujiPeripheral"

    // MARK: - Public

    /// Connects, pairs if needed, asks for Wi-Fi and returns its credentials.
    func requestWiFi(clientName: String) async throws -> FujiWiFiCredentials {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        try await waitForPoweredOn()

        let cam = try await findCamera()
        peripheral = cam
        cam.delegate = self
        onStatus("Connecting to \(cam.name ?? "the camera") over Bluetooth…")
        try await connect(cam)
        UserDefaults.standard.set(cam.identifier.uuidString, forKey: Self.savedPeripheralKey)
        try await discoverEverything(cam)

        onStatus("Pairing… if iOS asks to pair, tap Pair (and confirm the code on the camera)")
        try await pair(cam, clientName: clientName)

        for (svc, chr) in FujiBLEUUID.subscriptions {
            if let c = characteristics[CBUUID(string: chr)], c.service?.uuid == CBUUID(string: svc),
               c.properties.contains(.notify) || c.properties.contains(.indicate) {
                cam.setNotifyValue(true, for: c)
            }
        }

        onStatus("Asking the camera to turn on its Wi-Fi…")
        return try await askForWiFi(cam)
    }

    func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    // MARK: - Steps

    private func waitForPoweredOn() async throws {
        switch central.state {
        case .poweredOn: return
        case .unauthorized: throw PTPError("Bluetooth permission is off (Settings › Tetherview › Bluetooth)")
        case .unsupported: throw PTPError("This device doesn't support Bluetooth LE")
        default: break
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            poweredOn = c
        }
    }

    private func findCamera() async throws -> CBPeripheral {
        // 1. Already connected (e.g. XApp holds a link to it).
        let connectedNow = central.retrieveConnectedPeripherals(withServices: [
            FujiBLEUUID.securePairService, FujiBLEUUID.wifiService, FujiBLEUUID.shutterService,
            FujiBLEUUID.legacyPairService, FujiBLEUUID.confService,
        ])
        if let p = connectedNow.first {
            log("BLE: camera already connected to this iPhone: \(p.name ?? "?")")
            return p
        }
        // 2. Scan. Cameras advertise Fujifilm's company ID (0x04D8).
        onStatus("Looking for the camera over Bluetooth… (camera on, Bluetooth on)")
        log("BLE: scanning")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        defer { central.stopScan() }
        return try await withThrowingTaskGroup(of: CBPeripheral.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
                    self.found = c
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw PTPError("No Fujifilm camera found over Bluetooth. Turn the camera on and check Bluetooth/SMARTPHONE SETTING › Bluetooth ON/OFF is ON.")
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch {
                self.found?.resume(throwing: error)
                self.found = nil
                throw error
            }
        }
    }

    private func connect(_ p: CBPeripheral) async throws {
        if p.state == .connected { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connected = c
            central.connect(p, options: nil)
        }
        log("BLE: connected")
    }

    private func discoverEverything(_ p: CBPeripheral) async throws {
        characteristics.removeAll()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            discovered = c
            p.discoverServices(nil)
        }
        log("BLE: \(characteristics.count) characteristics discovered")
    }

    private func pair(_ p: CBPeripheral, clientName: String) async throws {
        let name = Data(clientName.utf8)
        if let status = characteristics[FujiBLEUUID.secureStatus] {
            log("BLE: secure pairing")
            // Reading this encrypted value is what makes iOS bond with the
            // camera; the first read can fail while the pairing prompt is up.
            var value = Data()
            for attempt in 1...20 {
                do {
                    value = try await read(status)
                    break
                } catch {
                    log("BLE: status read attempt \(attempt): \(error.localizedDescription)")
                    if attempt == 20 { throw PTPError("Couldn't pair with the camera over Bluetooth: \(error.localizedDescription)") }
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            log("BLE: pairing status \(hexString(value))")
            if value.count >= 4 {
                var ack = value
                ack[ack.startIndex + 3] = 0x20
                try await write(status, ack)
            }
            if let c = characteristics[FujiBLEUUID.clientName] {
                try await write(c, name)
            }
        } else if let token = characteristics[FujiBLEUUID.legacyPairToken] {
            log("BLE: legacy pairing")
            guard let t = legacyToken else {
                throw PTPError("Put the camera in pairing mode (Bluetooth/SMARTPHONE SETTING › PAIRING REGISTRATION) and try again.")
            }
            try await write(token, t)
            if let c = characteristics[FujiBLEUUID.clientName] {
                try await write(c, name)
            }
        } else {
            throw PTPError("This camera doesn't expose a known Fujifilm pairing service. Copy the log and share it so support can be added.")
        }
        log("BLE: paired")
    }

    private func askForWiFi(_ p: CBPeripheral) async throws -> FujiWiFiCredentials {
        guard let ssidChr = characteristics[FujiBLEUUID.wifiSSID],
              let request = characteristics[FujiBLEUUID.wifiRequest],
              let passChr = characteristics[FujiBLEUUID.wifiPassword] else {
            throw PTPError("The camera doesn't expose the Wi-Fi handover characteristics.")
        }
        let ssid = cleanString(try await read(ssidChr))
        log("BLE: camera Wi-Fi name \(ssid)")
        try await write(request, Data([0x04, 0x00]))
        let password = cleanString(try await read(passChr))
        log("BLE: camera Wi-Fi password received (\(password.count) characters)")

        // The camera indicates 01 on a68e3f66 when its access point is up.
        onStatus("Waiting for the camera's Wi-Fi to come up…")
        let ready = await waitForAPReady(timeout: 12)
        log("BLE: access point status \(String(format: "%02X", ready))")
        if ready == 0 {
            throw PTPError("The camera says it's busy. Close any menu on the camera and try again.")
        }
        return FujiWiFiCredentials(ssid: ssid, password: password)
    }

    private func waitForAPReady(timeout: TimeInterval) async -> UInt8 {
        if let c = characteristics[FujiBLEUUID.apReadyIndication], let v = c.value, let b = v.first, b == 1 {
            return 1
        }
        return await withCheckedContinuation { (c: CheckedContinuation<UInt8, Never>) in
            apReady = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self, let pending = self.apReady else { return }
                self.apReady = nil
                pending.resume(returning: 0xFF) // unknown: carry on and try Wi-Fi anyway
            }
        }
    }

    // MARK: - GATT helpers

    private func read(_ c: CBCharacteristic) async throws -> Data {
        guard let p = peripheral else { throw PTPError("Bluetooth disconnected") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            reads[c.uuid] = cont
            p.readValue(for: c)
        }
    }

    private func write(_ c: CBCharacteristic, _ data: Data) async throws {
        guard let p = peripheral else { throw PTPError("Bluetooth disconnected") }
        if c.properties.contains(.write) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                writes[c.uuid] = cont
                p.writeValue(data, for: c, type: .withResponse)
            }
        } else {
            p.writeValue(data, for: c, type: .withoutResponse)
        }
        log("BLE: wrote \(hexString(data)) to \(c.uuid.uuidString.prefix(8))")
    }

    private func cleanString(_ d: Data) -> String {
        let trimmed = d.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private func hexString(_ d: Data) -> String {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func failAll(_ error: Error) {
        connected?.resume(throwing: error); connected = nil
        discovered?.resume(throwing: error); discovered = nil
        for (_, c) in reads { c.resume(throwing: error) }
        reads.removeAll()
        for (_, c) in writes { c.resume(throwing: error) }
        writes.removeAll()
    }
}

// MARK: - CoreBluetooth delegates (all delivered on the main queue)

extension FujiBLE: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            log("BLE: state \(central.state.rawValue)")
            switch central.state {
            case .poweredOn:
                poweredOn?.resume(); poweredOn = nil
            case .unauthorized:
                poweredOn?.resume(throwing: PTPError("Bluetooth permission is off (Settings › Tetherview › Bluetooth)")); poweredOn = nil
            case .poweredOff:
                poweredOn?.resume(throwing: PTPError("Bluetooth is off")); poweredOn = nil
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let isFuji = (mfg.map { $0.count >= 2 && $0[$0.startIndex] == 0xD8 && $0[$0.startIndex + 1] == 0x04 } ?? false)
                || services.contains(where: { FujiBLEUUID.advertised.contains($0) })
            guard isFuji else { return }
            if !seen.contains(peripheral.identifier) {
                seen.insert(peripheral.identifier)
                log("BLE: found \(peripheral.name ?? "camera") rssi \(RSSI) mfg \(mfg.map { hexString($0) } ?? "-") services \(services.map { $0.uuidString.prefix(8) })")
            }
            // Legacy pairing mode: company ID, type 0x02, 4-byte token.
            if let m = mfg, m.count >= 7, m[m.startIndex + 2] == 0x02 {
                legacyToken = Data(m[(m.startIndex + 3)..<(m.startIndex + 7)])
            }
            found?.resume(returning: peripheral)
            found = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connected?.resume(); connected = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            connected?.resume(throwing: error ?? PTPError("Bluetooth connection failed")); connected = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            log("BLE: disconnected \(error?.localizedDescription ?? "")")
            failAll(error ?? PTPError("Bluetooth disconnected"))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error = error {
                discovered?.resume(throwing: error); discovered = nil
                return
            }
            let services = peripheral.services ?? []
            log("BLE: services " + services.map { String($0.uuid.uuidString.prefix(8)) }.joined(separator: " "))
            servicesLeft = services.count
            if services.isEmpty { discovered?.resume(); discovered = nil }
            for s in services { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] { characteristics[c.uuid] = c }
            servicesLeft -= 1
            if servicesLeft <= 0 { discovered?.resume(); discovered = nil }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let cont = reads.removeValue(forKey: characteristic.uuid) {
                if let error = error { cont.resume(throwing: error) } else { cont.resume(returning: characteristic.value ?? Data()) }
                return
            }
            // Notification / indication.
            let v = characteristic.value ?? Data()
            if characteristic.uuid == FujiBLEUUID.apReadyIndication, let b = v.first {
                apReady?.resume(returning: b); apReady = nil
            }
            log("BLE: notify \(characteristic.uuid.uuidString.prefix(8)) = \(hexString(v))")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let cont = writes.removeValue(forKey: characteristic.uuid) else { return }
            if let error = error { cont.resume(throwing: error) } else { cont.resume() }
        }
    }
}
