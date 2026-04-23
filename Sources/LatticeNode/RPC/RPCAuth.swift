import Foundation
import Hummingbird
import HTTPTypes

public enum RPCAuthMode: Sendable {
    case none
    case cookie(path: URL)
}

public struct RPCAuthConfig: Sendable {
    public let mode: RPCAuthMode

    public static let none = RPCAuthConfig(mode: .none)

    public static func cookie(dataDir: URL) -> RPCAuthConfig {
        RPCAuthConfig(mode: .cookie(path: dataDir.appendingPathComponent(".cookie")))
    }
}

public enum RPCAuthError: Error {
    case cookieGenerationFailed
}

public struct CookieAuth: Sendable {
    public let token: String
    public let path: URL

    public static func generate(at path: URL) throws -> CookieAuth {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Darwin)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw RPCAuthError.cookieGenerationFailed
        }
        #else
        guard let urandom = fopen("/dev/urandom", "r") else {
            throw RPCAuthError.cookieGenerationFailed
        }
        defer { fclose(urandom) }
        guard fread(&bytes, 1, 32, urandom) == 32 else {
            throw RPCAuthError.cookieGenerationFailed
        }
        #endif
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(to: path, atomically: true, encoding: .utf8)
        #if !os(Windows)
        chmod(path.path, 0o600)
        #endif
        return CookieAuth(token: token, path: path)
    }

    public static func load(from path: URL) throws -> CookieAuth {
        let token = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return CookieAuth(token: token, path: path)
    }

    public func validate(authHeader: String?) -> Bool {
        guard let header = authHeader else { return false }
        if header.hasPrefix("Bearer ") {
            return String(header.dropFirst(7)) == token
        }
        return header == token
    }

    public func validate(queryToken: String?) -> Bool {
        guard let queryToken else { return false }
        return queryToken == token
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: path)
    }
}

struct RPCAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let auth: CookieAuth?

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let auth = auth else {
            return try await next(request, context)
        }

        let authHeader = request.headers[.authorization]
        // EventSource cannot set headers; accept ?token= on loopback SSE endpoints as a
        // fallback. The token itself is still the same high-entropy cookie value.
        let queryToken = request.uri.queryParameters["token"].map(String.init)
        guard auth.validate(authHeader: authHeader) || auth.validate(queryToken: queryToken) else {
            var headers = HTTPFields()
            headers.append(HTTPField(name: .contentType, value: "application/json"))
            let body = Data("{\"error\":\"Unauthorized\"}".utf8)
            return Response(
                status: .unauthorized,
                headers: headers,
                body: .init(byteBuffer: .init(data: body))
            )
        }

        return try await next(request, context)
    }
}
