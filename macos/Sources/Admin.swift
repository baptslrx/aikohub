import AppKit
import Security
import SwiftUI

/// Une licence vue depuis le mode admin.
struct AdminLicence: Identifiable, Equatable {
    struct Device: Equatable { let id: String; let name: String; let lastSeen: String }
    let key: String
    let name: String
    let profile: String
    let maxDevices: Int
    let devices: [Device]
    let revoked: Bool
    let expires: String?
    let created: String
    var id: String { key }

    init(_ d: [String: Any]) {
        key = d["key"] as? String ?? ""
        name = d["name"] as? String ?? ""
        profile = d["profile"] as? String ?? ""
        maxDevices = d["maxDevices"] as? Int ?? 2
        revoked = d["revoked"] as? Bool ?? false
        expires = d["expires"] as? String
        created = d["created"] as? String ?? ""
        devices = (d["devices"] as? [[String: Any]] ?? []).map {
            Device(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "Mac", lastSeen: $0["lastSeen"] as? String ?? "")
        }
    }

    var message: String {
        let profileName = ["design": "Design", "monteur": "Monteur", "dev": "Dev", "tout": "Tout"][profile] ?? profile
        return """
        Salut \(name) ! Voici ta clé AikoHub (profil \(profileName)) :

        \(key)

        Ouvre AikoHub, colle la clé, puis choisis les outils à installer. Elle fonctionne sur \(maxDevices) Mac.
        """
    }
}

@MainActor
final class AdminModel: ObservableObject {
    @Published var password: String
    @Published var licences: [AdminLicence] = []
    @Published var error: String?
    @Published var busy = false
    @Published var newName = ""
    @Published var newProfile = "monteur"
    @Published var newMax = 2
    @Published var newHasEnd = false
    @Published var newEnd = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    @Published var justCreated: AdminLicence?
    /// Vrai seulement après une connexion acceptée par le serveur.
    @Published var authenticated = false
    var client = LicenseClient()

    init() {
        password = ""
        // Les anciennes versions retenaient le mot de passe : on l'efface, il faut le taper à chaque fois
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "fr.aikographic.aikohub",
                                kSecAttrAccount as String: "admin"]
        SecItemDelete(q as CFDictionary)
    }

    /// Quitte le mode admin : mot de passe oublié, liste effacée.
    func logout() {
        authenticated = false
        password = ""
        licences = []
        justCreated = nil
        error = nil
    }

    private func call(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        busy = true
        defer { busy = false }
        do {
            let r = try await client.post(path, body, admin: password)
            error = nil
            return r
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func load() async {
        guard let r = await call("/admin/list", [:]) else { authenticated = false; licences = []; return }
        authenticated = true
        licences = (r["licences"] as? [[String: Any]] ?? []).map(AdminLicence.init)
    }

    func create() async {
        guard authenticated else { return }
        var body: [String: Any] = ["name": newName, "profile": newProfile, "maxDevices": newMax]
        if newHasEnd { body["expires"] = ISO8601DateFormatter().string(from: newEnd) }
        guard let r = await call("/admin/create", body), let l = r["licence"] as? [String: Any] else { return }
        justCreated = AdminLicence(l)
        newName = ""
        await load()
    }

    func update(_ key: String, _ changes: [String: Any]) async {
        var body = changes
        body["key"] = key
        _ = await call("/admin/update", body)
        await load()
    }

    func delete(_ key: String) async {
        _ = await call("/admin/delete", ["key": key])
        await load()
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct AdminView: View {
    @ObservedObject var model: AdminModel
    var onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    static let profiles = [("design", "Design"), ("monteur", "Monteur"), ("dev", "Dev"), ("tout", "Tout")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: model.authenticated ? "lock.open.fill" : "lock.fill").foregroundStyle(Theme.accentText(scheme))
                Text("Mode admin · licences").font(.system(size: 18, weight: .semibold))
                Spacer()
                if model.authenticated {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Se déconnecter") { model.logout() }
                }
                Button("Fermer") { model.logout(); onClose() }
            }
            if model.authenticated {
                if let e = model.error { Text(e).foregroundStyle(.red).font(.system(size: 12)) }
                content
            } else {
                login
            }
        }
        .padding(22)
        .frame(minWidth: 860, minHeight: 600)
        .background(Theme.background(scheme))
    }

    /// Avant la connexion, on ne montre rien d'autre que le mot de passe.
    private var login: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(Theme.accentText(scheme))
            Text("Réservé à l'administrateur").font(.system(size: 16, weight: .semibold))
            HStack {
                SecureField("Mot de passe administrateur", text: $model.password)
                    .textFieldStyle(.roundedBorder).frame(width: 280)
                    .onSubmit { Task { await model.load() } }
                Button("Se connecter") { Task { await model.load() } }
                    .keyboardShortcut(.defaultAction).tint(Theme.accentUI)
                    .disabled(model.password.isEmpty || model.busy)
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let e = model.error { Text(e).foregroundStyle(.red).font(.system(size: 12)) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            card("Nouvelle clé") {
                HStack(spacing: 10) {
                    TextField("Nom de la personne", text: $model.newName).frame(width: 200)
                    Picker("", selection: $model.newProfile) {
                        ForEach(Self.profiles, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented).frame(width: 300).labelsHidden()
                    Stepper("\(model.newMax) Mac", value: $model.newMax, in: 1...10).frame(width: 110)
                }
                HStack {
                    Toggle("Date de fin", isOn: $model.newHasEnd)
                    if model.newHasEnd { DatePicker("", selection: $model.newEnd, displayedComponents: .date).labelsHidden() }
                    Spacer()
                    Button("Créer la clé") { Task { await model.create() } }
                        .keyboardShortcut(.defaultAction).tint(Theme.accentUI)
                        .disabled(model.newName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
                if let l = model.justCreated {
                    HStack {
                        Text(l.key).font(.system(size: 18, weight: .bold).monospaced()).textSelection(.enabled)
                        Button("Copier la clé") { AdminModel.copy(l.key) }
                        Button("Copier le message à envoyer") { AdminModel.copy(l.message) }
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentUI.opacity(0.15)))
                }
            }
            card("Licences (\(model.licences.count))") {
                if model.licences.isEmpty {
                    Text("Aucune licence pour l'instant.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.licences) { l in row(l) }
                    }
                }
            }
        }
    }

    private func row(_ l: AdminLicence) -> some View {
        HStack(alignment: .top) {
            info(l)
            Spacer()
            actions(l)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface(scheme)))
    }

    private func profileName(_ p: String) -> String { Self.profiles.first { $0.0 == p }?.1 ?? p }

    private func devicesLine(_ l: AdminLicence) -> String {
        let names = l.devices.isEmpty ? "aucun" : l.devices.map(\.name).joined(separator: ", ")
        let end = l.expires.map { " · jusqu'au " + String($0.prefix(10)) } ?? ""
        return "\(l.devices.count)/\(l.maxDevices) Mac : \(names)\(end)"
    }

    private func info(_ l: AdminLicence) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(l.name).font(.system(size: 13, weight: .semibold))
                Text(profileName(l.profile))
                    .font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accentUI.opacity(0.2))).foregroundStyle(Theme.accentText(scheme))
                if l.revoked { Text("DÉSACTIVÉE").font(.system(size: 10, weight: .bold)).foregroundStyle(.red) }
            }
            Text(l.key).font(.system(size: 11).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text(devicesLine(l)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func actions(_ l: AdminLicence) -> some View {
        HStack {
            Button { AdminModel.copy(l.message) } label: { Image(systemName: "doc.on.doc") }.help("Copier le message avec la clé")
            Button("Libérer les Mac") { Task { await model.update(l.key, ["resetDevices": true]) } }.disabled(l.devices.isEmpty)
            Button(l.revoked ? "Réactiver" : "Désactiver") { Task { await model.update(l.key, ["revoked": !l.revoked]) } }
            Button(role: .destructive) { confirmDelete(l) } label: { Image(systemName: "trash") }
        }
    }

    private func confirmDelete(_ l: AdminLicence) {
        let a = NSAlert()
        a.messageText = "Supprimer la clé de \(l.name) ?"
        a.informativeText = "Elle ne fonctionnera plus sur aucun Mac (au plus tard 30 jours sans connexion)."
        a.addButton(withTitle: "Supprimer")
        a.addButton(withTitle: "Annuler")
        if a.runModal() == .alertFirstButtonReturn { Task { await model.delete(l.key) } }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText(scheme))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface(scheme).opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line(scheme)))
        }
    }
}
