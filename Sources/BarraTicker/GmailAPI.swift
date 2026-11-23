import Foundation
import AppKit
import Network
import CryptoKit
import Security

// MARK: - Secretos (tokens de Google)
//
// Se guardan en un archivo privado (permisos 600) dentro de Application Support, no en el Llavero:
// la app se firma de nuevo en cada compilación y el Llavero volvería a pedir permiso cada vez.

enum SecretStore {
    private static let lock = NSLock()

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarraTicker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return d
    }

    private static func save(_ d: [String: String]) {
        guard let data = try? JSONEncoder().encode(d) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[key]
    }

    static func set(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        var d = load()
        d[key] = value
        save(d)
    }

    static func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var d = load()
        d[key] = nil
        save(d)
    }
}

struct GoogleError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Servidor local para recibir la redirección de Google

final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var result: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var done = false
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let e):
                    done = true
                    cont.resume(throwing: e)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            var query: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
            }
            let body = "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh\"><h2>Listo ✅</h2><p>Ya podés volver a Kappa.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n" + body
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if query["code"] != nil || query["error"] != nil { self?.finish(.success(query)) }
        }
    }

    func finish(_ r: Result<[String: String], Error>) {
        lock.lock()
        if result != nil { lock.unlock(); return }
        result = r
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(with: r)
    }

    func waitForResult(timeout: TimeInterval) async throws -> [String: String] {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(GoogleError(message: "Se agotó el tiempo esperando el inicio de sesión")))
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let r = result {
                lock.unlock()
                cont.resume(with: r)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }

    func stop() { listener.cancel() }
}

// MARK: - Inicio de sesión con Google (OAuth, una sola vez)

enum GoogleAuth {
    static let clientSecretKey = "google.clientSecret"
    private static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    private static let lock = NSLock()
    private static var tokenCache: [String: (token: String, expires: Date)] = [:]

    static func refreshKey(_ email: String) -> String { "refresh:" + email }

    private static func randomString(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return base64url(Data(bytes))
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let s = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    private static func postToken(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(fields)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Abre el navegador, espera el permiso y guarda el token de renovación. Devuelve el email de la cuenta.
    static func signIn(clientID: String, clientSecret: String) async throws -> String {
        let verifier = randomString(48)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomString(16)

        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "state", value: state)
        ]
        await MainActor.run { _ = NSWorkspace.shared.open(comps.url!) }

        let q = try await server.waitForResult(timeout: 240)
        if let err = q["error"] { throw GoogleError(message: "Google respondió: \(err)") }
        guard q["state"] == state, let code = q["code"] else {
            throw GoogleError(message: "Respuesta inválida de Google")
        }

        let tok = try await postToken([
            "code": code, "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier
        ])
        guard let access = tok["access_token"] as? String else {
            throw GoogleError(message: (tok["error_description"] as? String) ?? (tok["error"] as? String) ?? "No se pudo obtener el token")
        }
        guard let refresh = tok["refresh_token"] as? String else {
            throw GoogleError(message: "Google no entregó token de renovación. Revocá el acceso de Kappa en myaccount.google.com/permissions y probá de nuevo.")
        }

        let profile = try await GmailAPI.getJSON("https://gmail.googleapis.com/gmail/v1/users/me/profile", token: access)
        guard let email = (profile["emailAddress"] as? String)?.lowercased() else {
            throw GoogleError(message: "No pude leer el email de la cuenta")
        }
        SecretStore.set(refresh, for: refreshKey(email))
        cache(email, token: access, expiresIn: tok["expires_in"] as? Double ?? 3000)
        return email
    }

    private static func cache(_ email: String, token: String, expiresIn: Double) {
        lock.lock(); defer { lock.unlock() }
        tokenCache[email] = (token, Date().addingTimeInterval(expiresIn - 60))
    }

    static func forget(_ email: String) {
        SecretStore.remove(refreshKey(email))
        lock.lock(); tokenCache[email] = nil; lock.unlock()
    }

    static func accessToken(for email: String, clientID: String) async throws -> String {
        lock.lock()
        if let c = tokenCache[email], c.expires > Date() { lock.unlock(); return c.token }
        lock.unlock()

        guard let refresh = SecretStore.get(refreshKey(email)),
              let secret = SecretStore.get(clientSecretKey) else {
            throw GoogleError(message: "Falta iniciar sesión")
        }
        let tok = try await postToken([
            "client_id": clientID, "client_secret": secret,
            "refresh_token": refresh, "grant_type": "refresh_token"
        ])
        guard let access = tok["access_token"] as? String else {
            let reason = (tok["error"] as? String) ?? "desconocido"
            throw GoogleError(message: reason == "invalid_grant"
                              ? "La sesión de Google venció. Volvé a agregar la cuenta."
                              : "No se pudo renovar la sesión (\(reason))")
        }
        cache(email, token: access, expiresIn: tok["expires_in"] as? Double ?? 3000)
        return access
    }
}

// MARK: - Gmail API (solo lectura)

enum GmailAPI {
    static func getJSON(_ url: String, token: String) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw GoogleError(message: "URL inválida") }
        var req = URLRequest(url: u)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw GoogleError(message: msg)
        }
        return json
    }

    /// Mails sin leer de hoy en la bandeja de entrada. No modifica nada.
    static func unreadToday(email: String, clientID: String) async throws -> [MailMessage] {
        let token = try await GoogleAuth.accessToken(for: email, clientID: clientID)
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let q = "is:unread in:inbox after:\(start)"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let list = try await getJSON("https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=30&q=\(q)", token: token)
        let ids = ((list["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }

        var out: [MailMessage] = []
        for gid in ids {
            let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(gid)?format=metadata"
                + "&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Message-ID"
            guard let m = try? await getJSON(url, token: token) else { continue }

            var headers: [String: String] = [:]
            for h in ((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? [] {
                if let n = (h["name"] as? String)?.lowercased(), let v = h["value"] as? String { headers[n] = v }
            }
            let ms = Double((m["internalDate"] as? String) ?? "") ?? Date().timeIntervalSince1970 * 1000
            var id = (headers["message-id"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            if id.isEmpty { id = "gmail-" + gid }
            let who = email.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) ?? email
            out.append(MailMessage(id: id,
                                   account: email,
                                   sender: decodeWords(headers["from"] ?? ""),
                                   subject: decodeWords(headers["subject"] ?? "(sin asunto)"),
                                   date: Date(timeIntervalSince1970: ms / 1000),
                                   link: URL(string: "https://mail.google.com/mail/?authuser=\(who)#all/\(gid)")))
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Decodifica "=?UTF-8?B?...?=" y "=?UTF-8?Q?...?=" (acentos en remitentes y asuntos).
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?"),
              let re = try? NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        var prevEncoded = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(prevEncoded && gap.trimmingCharacters(in: .whitespaces).isEmpty) { result += gap }

            let charset = ns.substring(with: m.range(at: 1))
            let kind = ns.substring(with: m.range(at: 2)).lowercased()
            var text = ns.substring(with: m.range(at: 3))

            var data: Data?
            if kind == "b" {
                while text.count % 4 != 0 { text += "=" }
                data = Data(base64Encoded: text)
            } else {
                data = qDecode(text)
            }
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            let nsEnc = cf == kCFStringEncodingInvalidId
                ? String.Encoding.utf8.rawValue
                : CFStringConvertEncodingToNSStringEncoding(cf)
            if let data, let str = String(data: data, encoding: String.Encoding(rawValue: nsEnc)) {
                result += str
            } else {
                result += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
            prevEncoded = true
        }
        result += ns.substring(from: last)
        return result
    }

    private static func qDecode(_ s: String) -> Data {
        var out = Data()
        let b = Array(s.utf8)
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "_") {
                out.append(0x20)
            } else if b[i] == UInt8(ascii: "="), i + 2 < b.count,
                      let v = UInt8(String(decoding: b[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 2
            } else {
                out.append(b[i])
            }
            i += 1
        }
        return out
    }
}
