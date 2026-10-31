import Foundation

/// Both audio directions stay on loopback and never forward content through redirects.
enum LocalAudioConnection {
    static let session = URLSession(configuration: .ephemeral, delegate: NoAudioRedirects(), delegateQueue: nil)

    static func endpoint(setting: String, defaultPath: String) throws -> URL {
        let address = Config.value(setting) ?? "http://127.0.0.1:8870/\(defaultPath)"
        guard let endpoint = URL(string: address),
            ["http", "https"].contains(endpoint.scheme ?? ""),
            ["localhost", "127.0.0.1", "[::1]"].contains(endpoint.host ?? "")
        else { throw ToolError.failed("The voice service address must point to localhost.") }
        return endpoint
    }
}

private final class NoAudioRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
