import Foundation

/// Simple HTTP-style request/response over Unix socket.
struct HTTPRequest {
    let method: String
    let path: String
    let body: Data?

    /// Parse an HTTP request from raw data.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let lines = str.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let method = parts[0]
        let path = parts[1]

        // Find body (after empty line)
        if let emptyLineIndex = lines.firstIndex(of: "") {
            let bodyLines = lines[(emptyLineIndex + 1)...]
            let bodyStr = bodyLines.joined(separator: "\r\n")
            let body = bodyStr.data(using: .utf8)
            return HTTPRequest(method: method, path: path, body: body)
        }

        return HTTPRequest(method: method, path: path, body: nil)
    }
}

struct HTTPResponse {
    let statusCode: Int
    let body: Data?

    var statusText: String {
        switch statusCode {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 402: return "Payment Required"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }

    func serialize() -> Data {
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        if let body = body {
            response += "Content-Length: \(body.count)\r\n"
        } else {
            response += "Content-Length: 0\r\n"
        }
        response += "\r\n"

        var data = response.data(using: .utf8)!
        if let body = body {
            data.append(body)
        }
        return data
    }

    static func json(_ statusCode: Int, _ object: Any) -> HTTPResponse {
        let body = try? JSONSerialization.data(withJSONObject: object)
        return HTTPResponse(statusCode: statusCode, body: body)
    }

    static func error(_ statusCode: Int, _ message: String) -> HTTPResponse {
        json(statusCode, ["error": message])
    }

    static let notFound = error(404, "Not found")
}

/// Route handler type.
typealias RouteHandler = (HTTPRequest) async -> HTTPResponse

/// Simple path-based router.
class RequestRouter {
    private var routes: [(method: String, path: String, handler: RouteHandler)] = []

    func register(_ method: String, _ path: String, handler: @escaping RouteHandler) {
        routes.append((method: method, path: path, handler: handler))
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        for route in routes {
            if route.method == request.method && route.path == request.path {
                return await route.handler(request)
            }
        }
        return .notFound
    }
}
