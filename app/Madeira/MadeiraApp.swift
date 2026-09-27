import SwiftUI
import GameController

/// ml1001: the SwiftUI half of `GamepadEventClaim` (ContentView.swift). From
/// iOS 18 SwiftUI routes game-controller input into its own focus system unless
/// the hierarchy says it consumes the pad through GameController; without this
/// the analogue sticks reach the app only in brief bursts while buttons arrive
/// normally. Older systems have neither the behaviour nor the modifier.
private struct ClaimGamepadEvents: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.handlesGameControllerEvents(matching: .gamepad)
        } else {
            content
        }
    }
}

@main
struct MadeiraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
        }
    }
}

/// Identifies which build is installed: logged at launch and shown under
/// Setup Guide > About.
enum BuildInfo {

    /// When the app code was linked: the newer modification time of the executable
    /// and, in Debug builds, Madeira.debug.dylib (Xcode may leave the stub alone).
    static let builtAt: String = {
        var paths = [Bundle.main.executablePath].compactMap { $0 }
        paths.append(Bundle.main.bundlePath + "/Madeira.debug.dylib")
        let dates = paths.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        guard let date = dates.max() else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }()

    static var summary: String { "built \(builtAt)" }
}
