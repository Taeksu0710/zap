import SwiftUI
import AppKit

/// A bare `swift run`/command-line-launched SwiftUI app doesn't automatically
/// become the frontmost, key-window-owning app the way a double-clicked
/// `.app` bundle does — without this, the window is visible but never
/// receives keyboard focus, so typing into any TextField silently does
/// nothing.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let didOfferFDADefaultsKey = "net.youngsam.findfast.didOfferFDA"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)

        // Deferred to the next run-loop turn: `NSAlert.runModal()` spins a
        // nested run loop immediately, which would block this method from
        // returning before SwiftUI has drawn the window — the user would see
        // a blank window behind the alert instead of the real UI.
        DispatchQueue.main.async { [weak self] in
            self?.offerFullDiskAccessIfNeeded()
        }
    }

    /// Without Full Disk Access, scanning the home directory still works, but
    /// macOS prompts separately the first time it touches each protected
    /// folder (Desktop, Documents, Downloads, ...) — one interruption per
    /// folder, scattered across the scan instead of a single upfront choice.
    /// Granting Full Disk Access once eliminates all of those individually.
    ///
    /// Shown at most once: if the user dismisses with "Not Now", re-showing
    /// this on every single launch until they grant it would be exactly the
    /// kind of repeated-interruption annoyance it exists to prevent.
    private func offerFullDiskAccessIfNeeded() {
        guard !FullDiskAccess.isGranted else { return }
        guard !UserDefaults.standard.bool(forKey: Self.didOfferFDADefaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.didOfferFDADefaultsKey)

        let alert = NSAlert()
        alert.messageText = "Full Disk Access Recommended"
        alert.informativeText = """
            Zap scans your whole home folder, including Desktop, Documents, Downloads, and other protected locations. Without Full Disk Access, macOS will ask for permission separately for each one as scanning reaches it.

            Grant Full Disk Access once to skip all of those individual prompts. After granting, relaunch Zap.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            )
        }
    }
}

@main
struct FindFastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Zap") {
            ContentView()
        }
    }
}
