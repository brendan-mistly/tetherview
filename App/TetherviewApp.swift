import SwiftUI
import UIKit

@main
struct TetherviewApp: App {
    @StateObject private var camera = CameraManager()
    @StateObject private var wifi = WiFiManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MonitorView()
                .environmentObject(camera)
                .environmentObject(wifi)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    camera.start()
                    wifi.log = { [weak camera] line in camera?.log(line) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                camera.resume()
                wifi.appBecameActive()
            case .background:
                // Stop streaming and hand the camera's controls back.
                camera.suspend()
            default:
                break
            }
        }
    }
}
