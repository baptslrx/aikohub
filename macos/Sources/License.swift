import CryptoKit
import Foundation
import IOKit

/// Réglages du serveur de licences (remplis après sa mise en service).
enum Config {
    /// Adresse du serveur Cloudflare et clé publique qui vérifie les licences.
    static let defaultServer = "https://aikohub-licences.example.workers.dev"
    static let defaultPublicKey = ""

    /// Ordre : variable d'environnement (tests) → réglage → valeur gravée dans l'appli à la compilation.
    static var server: String {
        ProcessInfo.processInfo.environment["AIKO_SERVER"] ?? UserDefaults.standard.string(forKey: "server")
            ?? (Bundle.main.object(forInfoDictionaryKey: "AikoServer") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultServer
    }
    static var publicKey: String {
        ProcessInfo.processInfo.environment["AIKO_PUBLIC_KEY"] ?? UserDefaults.standard.string(forKey: "publicKey")
            ?? (Bundle.main.object(forInfoDictionaryKey: "AikoPublicKey") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultPublicKey
    }
    static var isConfigured: Bool { !publicKey.isEmpty && !server.contains("example") }
}

/// Contenu d'un jeton de licence (signé par le serveur).
struct LicensePayload: Codable, Equatable {
    let key: String
    let name: String
    let profile: String
    let device: String
    let issued: Int
    let validUntil: Int
    let tools: [String]

    var expiry: Date { Date(timeIntervalSince1970: TimeInterval(validUntil)) }
    var issuedDate: Date { Date(timeIntervalSince1970: TimeInterval(issued)) }

    var profileLabel: String {
        switch profile {
        case "design": return "Design"
        case "monteur": return "Monteur"
        case "dev": return "Dev"
        default: return "Tout"
        }
    }
}

enum Base64URL {
    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

enum LicenseVerifier {
    /// Vérifie la signature, l'appareil et la date. Fonctionne sans internet.
    static func verify(_ token: String, publicKey: String, device: String?, now: Date = Date()) -> LicensePayload? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 2, let body = Base64URL.decode(parts[0]), let sig = Base64URL.decode(parts[1]),
              let raw = Base64URL.decode(publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(sig, for: body),
              let p = try? JSONDecoder().decode(LicensePayload.self, from: body) else { return nil }
        if let device, p.device != device { return nil }
        guard p.expiry > now else { return nil }
        return p
    }
}

/// Identifiant de ce Mac (dérivé de son numéro matériel, jamais envoyé tel quel).
enum DeviceID {
    static var current: String {
        if let forced = ProcessInfo.processInfo.environment["AIKO_DEVICE_ID"] { return forced }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? Host.current().localizedName ?? "mac"
        let digest = SHA256.hash(data: Data(("aikohub:" + uuid).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static var name: String { Host.current().localizedName ?? "Mac" }
}

/// Licence enregistrée sur ce Mac (lue aussi par les outils Aiko au démarrage).
struct StoredLicense: Codable {
    var key: String
    var token: String
    var checked: Date

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AikoHub", isDirectory: true)
        if let custom = ProcessInfo.processInfo.environment["AIKO_LICENCE_DIR"] {
            return URL(fileURLWithPath: custom).appendingPathComponent("licence.json")
        }
        return dir.appendingPathComponent("licence.json")
    }

    static func load() -> StoredLicense? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(StoredLicense.self, from: Data(contentsOf: url))
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(self).write(to: Self.url, options: .atomic)
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }
}

/// Dialogue avec le serveur de licences.
struct LicenseClient {
    var server = Config.server

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func post(_ path: String, _ body: [String: Any], admin: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: server + path) else { throw ServerError(message: "Adresse du serveur invalide") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let admin { r.setValue("Bearer " + admin, forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: r)
        } catch {
            throw ServerError(message: "Pas de connexion au serveur de licences. Vérifie ta connexion internet.")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerError(message: "Réponse inattendue du serveur")
        }
        if obj["ok"] as? Bool != true { throw ServerError(message: obj["error"] as? String ?? "Erreur inconnue") }
        return obj
    }

    func activate(key: String) async throws -> String {
        let r = try await post("/activate", ["key": key, "device": DeviceID.current, "deviceName": DeviceID.name])
        return r["token"] as? String ?? ""
    }

    func refresh(key: String) async throws -> String {
        let r = try await post("/refresh", ["key": key, "device": DeviceID.current])
        return r["token"] as? String ?? ""
    }

    func deactivate(key: String) async throws {
        _ = try await post("/deactivate", ["key": key, "device": DeviceID.current])
    }

    func latestVersions() async -> [String: String] {
        guard let url = URL(string: server + "/catalog"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = obj["tools"] as? [String: [String: Any]] else { return [:] }
        return tools.compactMapValues { $0["version"] as? String }
    }

    func downloadURL(tool: String, token: String) -> URL? {
        var c = URLComponents(string: server + "/download/" + tool)
        c?.queryItems = [URLQueryItem(name: "t", value: token)]
        return c?.url
    }
}
