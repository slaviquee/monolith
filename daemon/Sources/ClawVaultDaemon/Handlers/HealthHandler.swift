import Foundation

/// GET /health — Status check (no auth required).
struct HealthHandler {
    static func handle(request: HTTPRequest) async -> HTTPResponse {
        .json(200, [
            "status": "ok",
            "version": "0.1.0",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ])
    }
}
