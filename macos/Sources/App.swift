import AppKit
import SwiftUI

@main
@MainActor
struct AikoHubMain {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let test = SelfTest(outDir: URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "screenshots"))
            app.setActivationPolicy(.regular)
            DispatchQueue.main.async { test.run() }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// Affichage du mode admin (ouvert seulement depuis le menu AikoHub, ⌥⌘A).
final class Nav: ObservableObject {
    @Published var showAdmin = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    let hub = HubModel()
    let admin = AdminModel()
    let nav = Nav()

    @objc func openAdmin() {
        nav.showAdmin = true
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos d'AikoHub", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let admin = NSMenuItem(title: "Mode admin…", action: #selector(openAdmin), keyEquivalent: "a")
        admin.keyEquivalentModifierMask = [.command, .option]
        admin.target = self
        appMenu.addItem(admin)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer AikoHub", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quitter AikoHub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        // Menu Édition : pour que ⌘V (coller la clé), ⌘C, ⌘A fonctionnent dans les champs
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let w = NSWindow(contentViewController: NSHostingController(rootView: RootView(hub: hub, admin: admin, nav: nav)))
        w.title = "AikoHub"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 940, height: 700))
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await hub.refreshIfNeeded()
            await hub.loadCatalog()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @ObservedObject var hub: HubModel
    @ObservedObject var admin: AdminModel
    @ObservedObject var nav: Nav
    @Environment(\.colorScheme) private var scheme

    init(hub: HubModel, admin: AdminModel, nav: Nav = Nav()) {
        self.hub = hub
        self.admin = admin
        self.nav = nav
    }

    var body: some View {
        Group {
            if nav.showAdmin {
                AdminView(model: admin) { nav.showAdmin = false }
            } else if hub.licence == nil {
                GateView(hub: hub)
            } else {
                HomeView(hub: hub)
            }
        }
        .background(Theme.background(scheme))
    }
}

// MARK: - Entrée de la clé

struct GateView: View {
    @ObservedObject var hub: HubModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Bienvenue dans AikoHub").font(.system(size: 26, weight: .bold))
            Text("Entre la clé qu'on t'a donnée pour débloquer tes outils.").font(.system(size: 14)).foregroundStyle(.secondary)
            HStack {
                TextField("AIKO-XXXX-XXXX-XXXX", text: $hub.keyInput)
                    .textFieldStyle(.roundedBorder).font(.system(size: 18, weight: .medium).monospaced())
                    .frame(width: 320)
                    .onSubmit { Task { await hub.activate() } }
                Button { Task { await hub.activate() } } label: { Text("Activer").frame(width: 90) }
                    .keyboardShortcut(.defaultAction).tint(Theme.accentUI).controlSize(.large)
                    .disabled(hub.busy || hub.keyInput.count < 8)
            }
            if hub.busy { ProgressView().controlSize(.small) }
            if let e = hub.error {
                Text(e).foregroundStyle(.red).font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            if !hub.configured {
                Text("Le serveur de licences n'est pas encore configuré.").font(.system(size: 12)).foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Text("Une clé fonctionne sur 2 Mac. Ensuite, AikoHub marche 30 jours sans internet entre deux vérifications.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Les outils

struct HomeView: View {
    @ObservedObject var hub: HubModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let e = hub.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.system(size: 12))
                    Spacer()
                    Button { hub.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(hub.tools) { t in toolRow(t) }
                    if !hub.lockedTools.isEmpty {
                        Text("PAS DANS TA LICENCE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
                        ForEach(hub.lockedTools) { t in lockedRow(t) }
                    }
                }
                .id(hub.refreshTick)
            }
            HStack {
                let n = hub.tools.filter { hub.chosen.contains($0.id) }.count
                Text(n == 0 ? "Coche les outils que tu veux installer." : "\(n) outil\(n > 1 ? "s" : "") sélectionné\(n > 1 ? "s" : "")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await hub.installChosen() } } label: {
                    Label("Installer la sélection", systemImage: "arrow.down.circle.fill")
                }
                .keyboardShortcut(.defaultAction).tint(Theme.accentUI).controlSize(.large)
                .disabled(n == 0 || !hub.working.isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 860, minHeight: 600)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Salut \(hub.licence?.name ?? "")").font(.system(size: 20, weight: .bold))
                    Text("Profil \(hub.licence?.profileLabel ?? "")").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentUI)).foregroundStyle(Theme.onAccent)
                }
                if let l = hub.licence {
                    Text("Licence vérifiée · valable sans internet jusqu'au \(l.expiry.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.wide)))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Vérifier la licence maintenant") { Task { await hub.refreshIfNeeded(force: true); await hub.loadCatalog() } }
                Button("Désactiver ce Mac (libère la place)") { Task { await hub.deactivateThisMac() } }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .menuStyle(.borderlessButton).frame(width: 40)
        }
    }

    private func toolRow(_ t: Tool) -> some View {
        let installed = t.installedURL != nil
        let status = hub.status(t)
        let update = status.hasPrefix("Mise à jour")
        return HStack(spacing: 14) {
            Toggle("", isOn: Binding(get: { hub.chosen.contains(t.id) },
                                     set: { if $0 { hub.chosen.insert(t.id) } else { hub.chosen.remove(t.id) } }))
                .labelsHidden().disabled(installed && !update)
            Image(systemName: t.symbol).font(.system(size: 22)).foregroundStyle(Theme.accentText(scheme)).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.app).font(.system(size: 14, weight: .semibold))
                Text(t.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(status).font(.system(size: 11, weight: .medium))
                .foregroundStyle(update ? Color.orange : (installed ? Theme.accentText(scheme) : Color.secondary))
            if hub.working[t.id] != nil {
                ProgressView().controlSize(.small)
            } else if installed {
                if update { Button("Mettre à jour") { Task { await hub.install(t) } } }
                Button("Ouvrir") { hub.open(t) }
                Menu {
                    Button("Réinstaller") { Task { await hub.install(t) } }
                    Button("Désinstaller (corbeille)") { hub.uninstall(t) }
                } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 24)
            } else {
                Button("Installer") { Task { await hub.install(t) } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line(scheme)))
    }

    private func lockedRow(_ t: Tool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 20)
            Image(systemName: t.symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 34)
            Text(t.app).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(t.summary).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
