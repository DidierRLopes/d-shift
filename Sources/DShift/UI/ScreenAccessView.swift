import ApplicationServices
import SwiftUI

/// Permissions belong to D-Shift, even when Chrome is the window being read.
struct ScreenAccessView: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenshots = CGPreflightScreenCaptureAccess()

    var body: some View {
        Group {
            if !accessibility || !screenshots {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "eye.slash")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            !accessibility
                                ? "Allow \(ScreenPermissions.owner) to read this window."
                                : "Allow screenshots for charts and images.")
                        Button(!accessibility ? "Enable Accessibility" : "Enable Screen Recording") {
                            let pane = !accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                    }
                    Spacer(minLength: 0)
                }
                .scaledFont(11)
                .padding(.horizontal, 16)
                .padding(.bottom, 9)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification))
        { _ in
            refresh()
        }
    }

    private func refresh() {
        accessibility = AXIsProcessTrusted()
        screenshots = CGPreflightScreenCaptureAccess()
    }
}
