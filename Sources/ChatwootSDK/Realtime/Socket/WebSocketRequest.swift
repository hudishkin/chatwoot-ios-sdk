import Foundation

enum WebSocketRequest {
    static func cableURL(baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/cable"
        components.query = nil
        return components.url!
    }

    static func origin(baseURL: URL) -> String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? baseURL.absoluteString
    }

    static func build(baseURL: URL) -> URLRequest {
        var request = URLRequest(url: cableURL(baseURL: baseURL))
        request.setValue(origin(baseURL: baseURL), forHTTPHeaderField: "Origin")
        request.timeoutInterval = 30
        return request
    }
}
