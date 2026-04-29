import Foundation
import Hummingbird
import HTTPTypes
import Synchronization

final class RPCRateLimiter: Sendable {
    private let state = Mutex(State())
    let requestsPerSecond: Int
    let burstSize: Int

    private struct State {
        var buckets: [String: Bucket] = [:]
        var lastCleanup: ContinuousClock.Instant = .now
    }

    private struct Bucket {
        var tokens: Double
        var lastRefill: ContinuousClock.Instant
    }

    init(requestsPerSecond: Int = 50, burstSize: Int = 100) {
        self.requestsPerSecond = requestsPerSecond
        self.burstSize = burstSize
    }

    func allow(ip: String) -> Bool {
        let now = ContinuousClock.Instant.now
        return state.withLock { s in
            if now - s.lastCleanup > .seconds(60) {
                s.buckets = s.buckets.filter { now - $0.value.lastRefill < .seconds(120) }
                s.lastCleanup = now
            }

            var bucket = s.buckets[ip] ?? Bucket(tokens: Double(burstSize), lastRefill: now)
            let elapsed = Double((now - bucket.lastRefill).components.seconds)
                + Double((now - bucket.lastRefill).components.attoseconds) / 1e18
            bucket.tokens = min(Double(burstSize), bucket.tokens + elapsed * Double(requestsPerSecond))
            bucket.lastRefill = now

            if bucket.tokens >= 1.0 {
                bucket.tokens -= 1.0
                s.buckets[ip] = bucket
                return true
            }
            s.buckets[ip] = bucket
            return false
        }
    }
}

struct RateLimitMiddleware<Context: RequestContext>: RouterMiddleware {
    let limiter: RPCRateLimiter

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let ip = request.headers[.init("X-Forwarded-For")!]
            ?? request.headers[.init("X-Real-IP")!]
            ?? "unknown"

        guard limiter.allow(ip: ip) else {
            var headers = HTTPFields()
            headers.append(HTTPField(name: .init("Retry-After")!, value: "1"))
            return Response(
                status: .tooManyRequests,
                headers: headers,
                body: .init(byteBuffer: .init(string: "{\"error\":\"rate limit exceeded\"}"))
            )
        }
        return try await next(request, context)
    }
}
