import SwiftUI
import UIKit

@main
struct TetherviewApp: App {
    @StateObject private var camera = CameraManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MonitorView()
                .environmentObject(camera)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    camera.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                camera.resume()
            case .background:
                // Stop streaming and hand the camera's controls back.
                camera.suspend()
            default:
                break
            }
        }
    }
}
