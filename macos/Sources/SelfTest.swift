import AppKit
import SwiftUI

/// `AikoHub --selftest <dossier>` : vrai serveur de licences lancé en local (wrangler dev) par le workflow.
@MainActor
final class SelfTest {
    let outDir: URL
    private var failures: [String] = []
    private var report: [String] = []
    private let ci = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil
    private let env = ProcessInfo.processInfo.environment

    init(outDir: URL) { self.outDir = outDir }

    func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            await steps()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            MainActor.assumeIsolated { self?.check(false, "le test a dépassé 3 minutes"); self?.finish() }
        }
    }

    private func log(_ s: String) { print(s); fflush(stdout); report.append(s) }
    private func check(_ ok: Bool, _ what: String) {
        log((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { failures.append(what); if ci { print("::error title=Test::\(what)") } }
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func steps() async {
        log("== Signature des licences (jeton créé par le serveur, vérifié par le Mac)")
        if let file = env["AIKO_TOKEN_FILE"], let data = FileManager.default.contents(atPath: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let token = obj["token"], let pub = obj["publicKey"], let forged = obj["forged"] {
            let p = LicenseVerifier.verify(token, publicKey: pub, device: "mac-1")
            check(p?.name == "Paul" && p?.profile == "monteur", "jeton valide lu hors ligne : \(p?.name ?? "—"), \(p?.profile ?? "—")")
            check(LicenseVerifier.verify(forged, publicKey: pub, device: "mac-1") == nil, "jeton trafiqué (profil « tout ») refusé")
            check(LicenseVerifier.verify(token, publicKey: pub, device: "autre-mac") == nil, "jeton copié sur un autre Mac refusé")
            check(LicenseVerifier.verify(token, publicKey: pub, device: "mac-1", now: Date().addingTimeInterval(31 * 86400)) == nil,
                  "après 30 jours sans connexion : à revérifier")
        } else {
            check(false, "jeton de test introuvable (AIKO_TOKEN_FILE)")
        }

        log("== Serveur de licences local : \(Config.server)")
        let admin = AdminModel()
        check(!admin.authenticated && admin.password.isEmpty, "mode admin fermé au départ, aucun mot de passe retenu")
        await snapshot(AdminView(model: admin, onClose: {}), name: "admin-verrouille")
        admin.newName = "Intrus"
        await admin.create()
        check(admin.justCreated == nil, "aucune clé créée sans connexion")
        admin.password = env["AIKO_ADMIN"] ?? ""
        await admin.load()
        check(admin.error == nil && admin.authenticated, "connexion admin : \(admin.error ?? "ok")")
        let wrong = AdminModel()
        wrong.password = "mauvais"
        await wrong.load()
        check(wrong.error?.contains("incorrect") == true && !wrong.authenticated, "mauvais mot de passe admin refusé")
        wrong.newName = "Intrus"
        await wrong.create()
        check(wrong.justCreated == nil, "aucune clé créée avec un mauvais mot de passe")

        admin.newName = "Camille"
        admin.newProfile = "monteur"
        await admin.create()
        guard let created = admin.justCreated else { check(false, "création de clé : \(admin.error ?? "")"); return }
        log("   clé créée : \(created.key)")
        check(created.key.hasPrefix("AIKO-") && created.maxDevices == 2, "clé AIKO-… pour 2 Mac")
        check(created.message.contains(created.key) && created.message.contains("Monteur"), "message à envoyer prêt")
        await snapshot(AdminView(model: admin, onClose: {}), name: "admin")

        log("== Activation dans AikoHub")
        let hub = HubModel()
        await snapshot(RootView(hub: hub, admin: AdminModel()), name: "cle")
        hub.keyInput = "aiko-0000-0000-0000"
        await hub.activate()
        check(hub.licence == nil && (hub.error ?? "").contains("n'existe pas"), "clé inconnue : « \(hub.error ?? "") »")
        hub.keyInput = created.key.lowercased()
        await hub.activate()
        check(hub.licence?.name == "Camille" && hub.licence?.profile == "monteur", "licence activée sur ce Mac")
        check(hub.tools.map(\.id).contains("aikorush") && hub.tools.map(\.id).contains("aikorelink")
              && !hub.tools.map(\.id).contains("aikodeploy"), "outils du profil Monteur seulement")
        check(StoredLicense.load() != nil, "licence enregistrée (les outils peuvent la lire)")
        await snapshot(RootView(hub: hub, admin: AdminModel()), name: "outils")

        let client = LicenseClient()
        let second = try? await client.post("/activate", ["key": created.key, "device": "mac-de-test-2", "deviceName": "iMac"])
        check(second != nil, "2e Mac accepté")
        do {
            _ = try await client.post("/activate", ["key": created.key, "device": "mac-de-test-3", "deviceName": "Mac mini"])
            check(false, "3e Mac aurait dû être refusé")
        } catch {
            check(error.localizedDescription.contains("2 appareils"), "3e Mac refusé : « \(error.localizedDescription.prefix(70))… »")
        }

        await hub.refreshIfNeeded(force: true)
        check(hub.licence != nil, "renouvellement de la licence")
        await admin.update(created.key, ["revoked": true])
        await hub.refreshIfNeeded(force: true)
        check(hub.licence == nil && (hub.error ?? "").contains("désactivée"), "clé désactivée par l'admin : AikoHub se verrouille")
        await admin.update(created.key, ["revoked": false])
        hub.keyInput = created.key
        await hub.activate()
        check(hub.licence != nil, "clé réactivée : ça remarche")
        await hub.deactivateThisMac()
        await admin.load()
        let devices = admin.licences.first { $0.key == created.key }?.devices.map(\.id) ?? []
        check(!devices.contains(DeviceID.current), "« Désactiver ce Mac » libère la place")

        log("== Installation d'un outil (archive comme celles des versions publiées)")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aikohub-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("build/AikoTest.app/Contents")
        try? FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try? """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.2.0</string></dict></plist>
        """.write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let zip = tmp.appendingPathComponent("AikoTest-Mac.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", tmp.appendingPathComponent("build/AikoTest.app").path, zip.path]
        try? p.run()
        p.waitUntilExit()
        let apps = tmp.appendingPathComponent("Applications")
        try? FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        do {
            let dest = try Installer.install(zip: zip, app: "AikoTest", into: apps)
            let v = Bundle(url: dest)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            check(v == "1.2.0", "appli décompressée et installée (version \(v ?? "?"))")
            _ = try Installer.install(zip: zip, app: "AikoTest", into: apps)
            check(true, "réinstallation par-dessus l'ancienne version")
        } catch {
            check(false, "installation : \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    private func snapshot<V: View>(_ view: V, name: String) async {
        for dark in [true, false] {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 940, height: 700)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = host
            w.orderFrontRegardless()
            await sleep(0.8)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = "\(name)-\(dark ? "sombre" : "clair").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(file))
                log("   capture \(file)")
            }
            w.orderOut(nil)
        }
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        log(failures.isEmpty ? "\nTout est OK" : "\nÉCHECS :\n" + failures.joined(separator: "\n"))
        try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("rapport.txt"), atomically: true, encoding: .utf8)
        exit(failures.isEmpty ? 0 : 1)
    }
}
