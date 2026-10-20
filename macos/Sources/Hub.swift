import AppKit

/// Un outil de la suite Aiko.
struct Tool: Identifiable, Equatable {
    let id: String          // nom du dépôt (aikoroue…)
    let app: String         // AikoRoue
    let bundleID: String
    let summary: String
    let symbol: String
    let profiles: [String]

    static let all: [Tool] = [
        Tool(id: "aikoroue", app: "AikoRoue", bundleID: "fr.aikographic.aikoroue",
             summary: "Maj + glisser un fichier : une roue pour le convertir (images, vidéos, PDF…)",
             symbol: "circle.dotted.circle", profiles: ["design", "monteur", "dev"]),
        Tool(id: "aikopipette", app: "AikoPipette", bundleID: "fr.aikographic.aikopipette",
             summary: "⌥C : prends une couleur n'importe où, historique et palette d'image",
             symbol: "eyedropper.halffull", profiles: ["design", "dev"]),
        Tool(id: "aikorush", app: "AikoRush", bundleID: "fr.aikographic.aikorush",
             summary: "Prépare tes rushs : copie rangée, proxys ProRes, son, marqueurs de silences",
             symbol: "film.stack", profiles: ["monteur"]),
        Tool(id: "aikorelink", app: "AikoRelink", bundleID: "fr.aikographic.aikorelink",
             summary: "Répare les médias hors ligne de DaVinci Resolve, même renommés",
             symbol: "link.badge.plus", profiles: ["monteur"]),
        Tool(id: "aikodeck", app: "AikoDeck", bundleID: "fr.aikographic.aikodeck",
             summary: "Ton téléphone devient un Stream Deck (DaVinci, musique, applis…)",
             symbol: "square.grid.3x3.square", profiles: ["design", "monteur"]),
        Tool(id: "aikoserve", app: "AikoServe", bundleID: "fr.aikographic.aikoserve",
             summary: "Ton site local sur ton téléphone avec un QR code, rechargement automatique, PHP",
             symbol: "qrcode", profiles: ["dev"]),
        Tool(id: "aikodeploy", app: "AikoDeploy", bundleID: "fr.aikographic.aikodeploy",
             summary: "Mise en ligne FTP / SFTP des seuls fichiers modifiés, avec retour arrière",
             symbol: "icloud.and.arrow.up", profiles: ["dev"]),
        Tool(id: "aikoshots", app: "AikoShots", bundleID: "fr.aikographic.aikoshots",
             summary: "Ton site sur 12 écrans d'un coup, et ce qui a changé depuis la dernière fois",
             symbol: "rectangle.3.group", profiles: ["design", "dev"]),
        Tool(id: "aikoflow", app: "AikoFlow", bundleID: "fr.aikographic.aikoflow",
             summary: "Fenêtres rangées automatiquement sur 9 pages, comme Hyprland",
             symbol: "square.grid.2x2", profiles: ["design", "monteur", "dev"]),
        Tool(id: "aikoshield", app: "AikoShield", bundleID: "fr.aikographic.aikoshield",
             summary: "Partage d'écran : e-mails, IBAN, codes et notifications masqués tout seuls",
             symbol: "checkmark.shield", profiles: ["design", "monteur", "dev"]),
        Tool(id: "aikomemo", app: "AikoMemo", bundleID: "fr.aikographic.aikomemo",
             summary: "La mémoire de ton Mac : « le pdf reçu sur WhatsApp hier »",
             symbol: "sparkle.magnifyingglass", profiles: ["design", "monteur", "dev"]),
    ]

    func allowed(for profile: String) -> Bool { profile == "tout" || profiles.contains(profile) }

    var installedURL: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return u }
        let u = URL(fileURLWithPath: "/Applications/\(app).app")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var installedVersion: String? {
        guard let u = installedURL else { return nil }
        return Bundle(url: u)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

/// Installe un outil à partir de son archive (téléchargée depuis le serveur, avec la licence).
enum Installer {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let data = (try? Data(contentsOf: file)) ?? Data()
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(message: msg ?? "Téléchargement refusé (\(http.statusCode))")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("aikohub-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }

    /// Décompresse l'archive et place l'appli dans le dossier d'applications (remplace l'ancienne version).
    @discardableResult
    static func install(zip: URL, app: String, into applications: URL = URL(fileURLWithPath: "/Applications")) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("aikohub-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, work.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(message: "Archive illisible") }
        guard let found = fm.enumerator(at: work, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "app" }) else {
            throw Failure(message: "Aucune appli dans l'archive")
        }
        // On ferme l'ancienne version si elle tourne
        for running in NSWorkspace.shared.runningApplications where running.bundleURL?.lastPathComponent == "\(app).app" {
            running.terminate()
        }
        let dest = applications.appendingPathComponent("\(app).app")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: found, to: dest)
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? x.run()
        x.waitUntilExit()
        return dest
    }

    static func uninstall(_ tool: Tool) throws {
        guard let u = tool.installedURL else { return }
        for running in NSWorkspace.shared.runningApplications where running.bundleIdentifier == tool.bundleID { running.terminate() }
        try FileManager.default.trashItem(at: u, resultingItemURL: nil)
    }
}

@MainActor
final class HubModel: ObservableObject {
    @Published var licence: LicensePayload?
    @Published var stored: StoredLicense?
    @Published var keyInput = ""
    @Published var error: String?
    @Published var busy = false
    @Published var chosen: Set<String> = []
    @Published var working: [String: String] = [:]     // outil → « Téléchargement… »
    @Published var latest: [String: String] = [:]
    @Published var refreshTick = 0                      // pour relire l'état des applis installées
    var client = LicenseClient()

    init() {
        stored = StoredLicense.load()
        verify()
    }

    var configured: Bool { Config.isConfigured }

    func verify() {
        guard let s = stored else { licence = nil; return }
        licence = LicenseVerifier.verify(s.token, publicKey: Config.publicKey, device: DeviceID.current)
    }

    var tools: [Tool] { Tool.all.filter { licence.map { l in $0.allowed(for: l.profile) } ?? false } }
    var lockedTools: [Tool] { Tool.all.filter { licence.map { l in !$0.allowed(for: l.profile) } ?? true } }

    func activate() async {
        let key = keyInput.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let token = try await client.activate(key: key)
            let s = StoredLicense(key: key, token: token, checked: Date())
            guard LicenseVerifier.verify(token, publicKey: Config.publicKey, device: DeviceID.current) != nil else {
                error = "Licence reçue mais invalide (serveur mal configuré ?)"
                return
            }
            s.save()
            stored = s
            verify()
            chosen = Set(tools.filter { $0.installedURL == nil }.map(\.id))
            await loadCatalog()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Renouvelle le jeton en arrière-plan (la licence fonctionne 30 jours hors ligne).
    func refreshIfNeeded(force: Bool = false) async {
        guard let s = stored else { return }
        if !force, let l = licence, l.expiry.timeIntervalSinceNow > 25 * 86400 { return }
        do {
            let token = try await client.refresh(key: s.key)
            var n = s
            n.token = token
            n.checked = Date()
            n.save()
            stored = n
            verify()
        } catch let e as LicenseClient.ServerError where !e.message.hasPrefix("Pas de connexion") {
            // Clé désactivée, expirée ou Mac libéré : la licence s'arrête
            StoredLicense.delete()
            stored = nil
            licence = nil
            error = e.message
        } catch {}
    }

    func deactivateThisMac() async {
        guard let s = stored else { return }
        try? await client.deactivate(key: s.key)
        StoredLicense.delete()
        stored = nil
        licence = nil
    }

    func loadCatalog() async {
        latest = await client.latestVersions()
    }

    func status(_ t: Tool) -> String {
        if let w = working[t.id] { return w }
        guard let v = t.installedVersion else { return "Pas installé" }
        if let l = latest[t.id], l.trimmingCharacters(in: CharacterSet(charactersIn: "v")) != v { return "Mise à jour \(l) disponible" }
        return "Installé · \(v)"
    }

    func install(_ t: Tool) async {
        guard let s = stored, let url = client.downloadURL(tool: t.id, token: s.token) else { return }
        working[t.id] = "Téléchargement…"
        defer { working[t.id] = nil; refreshTick += 1 }
        do {
            let zip = try await Installer.download(url)
            working[t.id] = "Installation…"
            let app = t.app
            try await Task.detached { try Installer.install(zip: zip, app: app) }.value
            try? FileManager.default.removeItem(at: zip)
            chosen.remove(t.id)
        } catch {
            self.error = "\(t.app) : \(error.localizedDescription)"
        }
    }

    func installChosen() async {
        for t in tools where chosen.contains(t.id) { await install(t) }
    }

    func open(_ t: Tool) {
        guard let u = t.installedURL else { return }
        NSWorkspace.shared.openApplication(at: u, configuration: .init())
    }

    func uninstall(_ t: Tool) {
        do { try Installer.uninstall(t) } catch { self.error = error.localizedDescription }
        refreshTick += 1
    }
}
