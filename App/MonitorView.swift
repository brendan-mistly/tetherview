import SwiftUI
import UIKit

struct MonitorView: View {
    @EnvironmentObject private var camera: CameraManager
    @EnvironmentObject private var wifi: WiFiManager

    @AppStorage("showGrid") private var showGrid = false
    @AppStorage("flip180") private var flip180 = false
    @AppStorage("mirror") private var mirror = false

    @State private var hudVisible = true
    @State private var hudHideTask: Task<Void, Never>?
    @State private var showLog = false

    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAtGestureStart: CGSize = .zero

    private var isLive: Bool { wifi.phase == .live || camera.phase == .live }
    private var currentFrame: UIImage? { wifi.isActive ? wifi.frame : camera.frame }
    private var liveName: String {
        wifi.isActive ? "Wi-Fi" : (camera.cameraName ?? "USB")
    }
    private var liveFPS: Double { wifi.isActive ? wifi.fps : camera.fps }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let frame = currentFrame {
                    liveImage(frame, in: geo.size)
                }

                if !isLive {
                    ScrollView {
                        statusCard
                            .padding(24)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }

                if hudVisible || !isLive {
                    hud
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleZoom() }
            .onTapGesture { toggleHUD() }
            .gesture(zoomGesture.simultaneously(with: panGesture))
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showLog) { LogView().environmentObject(camera) }
        .onChange(of: wifi.phase) { _, newPhase in
            if newPhase == .live { resetZoom(); scheduleHUDHide() }
        }
        .onAppear { scheduleHUDHide() }
    }

    // MARK: - Live image

    @ViewBuilder
    private func liveImage(_ frame: UIImage, in container: CGSize) -> some View {
        let fitted = fittedSize(image: frame.size, in: container)
        ZStack {
            Image(uiImage: frame)
                .resizable()
                .interpolation(.medium)
                .frame(width: fitted.width, height: fitted.height)
            if showGrid {
                GridOverlay()
                    .frame(width: fitted.width, height: fitted.height)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(x: mirror ? -1 : 1, y: 1)
        .rotationEffect(.degrees(flip180 ? 180 : 0))
        .scaleEffect(zoom)
        .offset(pan)
        .frame(width: container.width, height: container.height)
        .clipped()
    }

    private func fittedSize(image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    // MARK: - HUD

    private var hud: some View {
        VStack {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isLive ? Color.red : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(isLive ? liveName : "Not live")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                    if isLive {
                        Text(String(format: "%.0f fps", liveFPS))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if camera.hasControl {
                        Label("Camera dials locked", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                HStack(spacing: 6) {
                    hudButton(showGrid ? "grid.circle.fill" : "grid.circle", "Grid") { showGrid.toggle() }
                    hudButton("arrow.triangle.2.circlepath", "Flip 180°") { flip180.toggle() }
                    hudButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Mirror") { mirror.toggle() }
                    if zoom != 1 {
                        hudButton("1.magnifyingglass", "Reset zoom") { resetZoom() }
                    }
                    hudButton("list.bullet.rectangle", "Log") { showLog = true }
                    if wifi.isActive {
                        hudButton("xmark", "Disconnect") { wifi.stop() }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .foregroundStyle(.white)
    }

    private func hudButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHUDHide()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    // MARK: - Status card

    @ViewBuilder
    private var statusCard: some View {
        if wifi.isActive {
            card { wifiCard }
        } else {
            card { usbCard }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var wifiCard: some View {
        switch wifi.phase {
        case .idle, .live:
            EmptyView()

        case .bluetooth, .connecting:
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Wi-Fi").font(.title3.weight(.bold))
            }
            Text(wifi.status).font(.callout).foregroundStyle(.secondary)
            Button("Cancel") { wifi.stop() }.buttonStyle(.bordered)

        case .joinWiFi(let creds):
            Text("Join the camera's Wi-Fi").font(.title3.weight(.bold))
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open **Settings › Wi-Fi › Other…** (the camera's network is hidden).")
                HStack(spacing: 6) {
                    Text("2. Name:")
                    Text(creds.ssid).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button { UIPasteboard.general.string = creds.ssid } label: { Image(systemName: "doc.on.doc") }
                }
                Text("3. Security: **WPA2/WPA3 Personal**")
                HStack(spacing: 6) {
                    Text("4. Password (already copied — just paste):")
                    Text(creds.password).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button { UIPasteboard.general.string = creds.password } label: { Image(systemName: "doc.on.doc") }
                }
                Text("5. Come back here — it connects by itself.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Button("Open Settings") { openWiFiSettings() }.buttonStyle(.borderedProminent)
                Button("Connect now") { wifi.connectNow() }.buttonStyle(.bordered)
                Button("Cancel") { wifi.stop() }.buttonStyle(.bordered)
            }

        case .failed(let message):
            Text("Wi-Fi didn't connect").font(.title3.weight(.bold))
            Text(message).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Start over") { wifi.start() }.buttonStyle(.borderedProminent)
                Button("Connect now") { wifi.connectNow() }.buttonStyle(.bordered)
                Button("Log") { showLog = true }.buttonStyle(.bordered)
                Button("Cancel") { wifi.stop() }.buttonStyle(.bordered)
            }
        }
    }

    private func openWiFiSettings() {
        // The Wi-Fi page itself if iOS allows it, otherwise the Settings app.
        let wifiURL = URL(string: "App-Prefs:root=WIFI")!
        UIApplication.shared.open(wifiURL) { ok in
            if !ok, let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    @ViewBuilder
    private var usbCard: some View {
            switch camera.phase {
            case .waitingForCamera:
                Text("Connect your camera").font(.title3.weight(.bold))
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Wi-Fi** — X-T50, X-S20, X-T5, X100VI and other recent bodies")
                    Text("Camera on, Bluetooth on. Swipe Fujifilm's app closed first so it doesn't hold the camera.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack {
                    Button("Connect over Wi-Fi") { wifi.start() }.buttonStyle(.borderedProminent)
                    Button("Already on the camera's Wi-Fi") { wifi.connectNow() }.buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("**USB** — bodies with a tether mode (X-T5, X-H2…)")
                    Text("MENU › NETWORK/USB SETTING › CONNECTION MODE › USB TETHER SHOOTING AUTO, then plug in.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

            case .connecting:
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(camera.cameraName ?? "Camera").font(.title3.weight(.bold))
                }
                Text(camera.status).font(.callout).foregroundStyle(.secondary)

            case .needsControl:
                Text("Allow the app to take control?").font(.title3.weight(.bold))
                Text("Your camera only sends live view when the app takes control. While it's connected, the camera's dials and buttons are locked (the lens focus ring still works). Control is handed back when you unplug or close the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Allow control") { camera.grantControlAndRetry() }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { camera.retry() }
                        .buttonStyle(.bordered)
                }

            case .failed(let message):
                Text("Live view stopped").font(.title3.weight(.bold))
                Text(message).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Try again") { camera.retry() }
                        .buttonStyle(.borderedProminent)
                    Button("Show log") { showLog = true }
                        .buttonStyle(.bordered)
                }

            case .live:
                EmptyView()
            }
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(8, max(1, zoomAtGestureStart * value))
            }
            .onEnded { _ in
                zoomAtGestureStart = zoom
                if zoom <= 1.01 { resetZoom() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard zoom > 1 else { return }
                pan = CGSize(width: panAtGestureStart.width + value.translation.width,
                             height: panAtGestureStart.height + value.translation.height)
            }
            .onEnded { _ in panAtGestureStart = pan }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if zoom > 1 {
                resetZoom()
            } else {
                zoom = 3
                zoomAtGestureStart = 3
            }
        }
    }

    private func resetZoom() {
        zoom = 1
        zoomAtGestureStart = 1
        pan = .zero
        panAtGestureStart = .zero
    }

    private func toggleHUD() {
        withAnimation(.easeInOut(duration: 0.2)) { hudVisible.toggle() }
        if hudVisible { scheduleHUDHide() }
    }

    private func scheduleHUDHide() {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { hudVisible = false }
        }
    }
}

/// Rule-of-thirds grid.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 1)
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var camera: CameraManager
    @EnvironmentObject private var wifi: WiFiManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(camera.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(camera.logLines.count - 1, anchor: .bottom) }
            }
            .navigationTitle("Connection log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") { UIPasteboard.general.string = camera.logLines.joined(separator: "\n") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
