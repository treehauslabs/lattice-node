import Foundation
import Hummingbird
import HTTPTypes

public actor RPCRateLimiter {
    private var requestCounts: [String: (count: Int, windowStart: ContinuousClock.Instant)] = [:]
    private let maxRequestsPerWindow: Int
    private let windowDuration: Duration
    private let cleanupInterval: Int

    public init(
        maxRequestsPerWindow: Int = 100,
        windowDuration: Duration = .seconds(60),
        cleanupInterval: Int = 1000
    ) {
        self.maxRequestsPerWindow = maxRequestsPerWindow
        self.windowDuration = windowDuration
        self.cleanupInterval = cleanupInterval
    }

    public func shouldAllow(ip: String) -> Bool {
        let now = ContinuousClock.Instant.now

        if let entry = requestCounts[ip] {
            if now - entry.windowStart >= windowDuration {
                requestCounts[ip] = (count: 1, windowStart: now)
                return true
            }
            if entry.count >= maxRequestsPerWindow {
                return false
            }
            requestCounts[ip] = (count: entry.count + 1, windowStart: entry.windowStart)
        } else {
            requestCounts[ip] = (count: 1, windowStart: now)
        }

        if requestCounts.count > cleanupInterval {
            let cutoff = now - windowDuration
            requestCounts = requestCounts.filter { now - $0.value.windowStart < windowDuration }
        }

        return true
    }

    public func recordBadRequest(ip: String) {
        if var entry = requestCounts[ip] {
            entry.count += 10
            requestCounts[ip] = entry
        }
    }
}

struct RPCRateLimitMiddleware<Context: RequestContext>: RouterMiddleware {
    let rateLimiter: RPCRateLimiter

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let ip = extractIP(from: request)

        guard await rateLimiter.shouldAllow(ip: ip) else {
            var headers = HTTPFields()
            headers.append(HTTPField(name: .contentType, value: "application/json"))
            headers.append(HTTPField(name: .init("Retry-After")!, value: "60"))
            let body = Data("{\"error\":\"Rate limit exceeded\"}".utf8)
            return Response(
                status: .tooManyRequests,
                headers: headers,
                body: .init(byteBuffer: .init(data: body))
            )
        }

        let response = try await next(request, context)

        if response.status == .badRequest || response.status == .unauthorized {
            await rateLimiter.recordBadRequest(ip: ip)
        }

        return response
    }

    private func extractIP(from request: Request) -> String {
        if let forwarded = request.headers[.init("X-Forwarded-For")!] {
            return String(forwarded.split(separator: ",").first ?? Substring(forwarded))
                .trimmingCharacters(in: .whitespaces)
        }
        return "unknown"
    }
}
