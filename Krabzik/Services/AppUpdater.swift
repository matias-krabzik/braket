import Combine
import Sparkle

/// Sparkle verifica las firmas y usa el cierre normal de NSApplication,
/// que conserva la confirmación de documentos y la detención de procesos.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var canCheck = false
    @Published var automaticallyChecks = false {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published private(set) var lastCheck: Date?
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        controller.startUpdater()
    }

    func check() { controller.checkForUpdates(nil) }
}
