import SwiftUI

@main
struct MoyeReaderIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("moye.appearance") private var appearance = "system"

    init() {
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared.diskCapacity = 0
        URLCache.shared.memoryCapacity = 0
        MoyeReadingImageCache.shared.clearAll()
        MoyeReadingImageCache.covers.clear()
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            MoyeHomeView()
                .preferredColorScheme(preferredScheme)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    MoyeReadingImageCache.shared.clear()
                    MoyeReadingImageCache.covers.clear()
                    URLCache.shared.removeAllCachedResponses()
                }
        }
    }
}
