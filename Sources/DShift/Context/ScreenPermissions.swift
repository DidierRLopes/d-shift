import Foundation

enum ScreenPermissions {
    static var owner: String {
        Bundle.main.bundleURL.pathExtension == "app" ? "D-Shift" : "your terminal app"
    }

    static func guidance(for permission: String) -> String {
        var message =
            "\(permission) permission is missing. Enable \(owner) in System Settings > Privacy & Security > \(permission), then quit and reopen D-Shift."
        if Bundle.main.bundleURL.pathExtension == "app" {
            message += " If it is missing from the list, use + to add \(Bundle.main.bundleURL.path)."
        } else {
            message += " macOS attributes source launches to the terminal that ran D-Shift."
        }
        return message + " The permission belongs to the process running D-Shift, not Chrome or the app being viewed."
    }
}
