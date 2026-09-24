import SwiftUI
import UIKit

struct MonitorView: View {
    @EnvironmentObject private var camera: CameraManager

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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let frame = camera.frame {
                    liveImage(frame, in: geo.size)
                }

                if camera.phase != .live {
                    statusCard
                        .padding(24)
                }

                if hudVisible || camera.phase != .live {
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
                        .fill(camera.phase == .live ? Color.red : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(camera.phase == .live ? (camera.cameraName ?? "Live") : "Not live")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                    if camera.phase == .live {
                        Text(String(format: "%.0f fps", camera.fps))
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

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch camera.phase {
            case .waitingForCamera:
                Text("Connect your camera").font(.title3.weight(.bold))
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. On the camera: MENU › NETWORK/USB SETTING › USB › **USB TETHER SHOOTING AUTO**")
                    Text("2. Plug it into the iPhone with a USB-C cable that carries data.")
                    Text("3. Allow access if iOS asks.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

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
        .frame(maxWidth: 520, alignment: .leading)
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .foregroundStyle(.white)
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
