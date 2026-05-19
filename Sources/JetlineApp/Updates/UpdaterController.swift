import SwiftUI
import Sparkle

/// SwiftUI wrapper around `SPUStandardUpdaterController`. Held as an
/// `@StateObject` in `JetlineApp` so the updater's lifetime matches the App
/// scene. `startingUpdater: true` kicks off Sparkle's scheduled check loop
/// on launch.
@MainActor
final class UpdaterViewModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheck = false

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }
}

/// Menu item placed under "About Jetline" via `CommandGroup(after: .appInfo)`.
/// Disabled while Sparkle is mid-check so the user can't queue concurrent runs.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject var vm: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…") {
            vm.controller.checkForUpdates(nil)
        }
        .disabled(!vm.canCheck)
    }
}
