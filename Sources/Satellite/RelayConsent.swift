import AppKit

/// Asks the user before an extension joins a room group or uses a store on the relay, once per name, the way
/// Ghostship asks per channel, room group or store (AGENTS.md, section 5). The manifest permission says what kind of
/// thing an extension may do; this says where. An answer of Allow is kept (per extension, in UserDefaults
/// `relay.consent.<id>`) until the extension is uninstalled; Don't Allow lasts until Satellite quits, so a page
/// that keeps retrying doesn't keep asking.
@MainActor
final class RelayConsent {
    static let shared = RelayConsent()

    enum Kind: String {
        case roomGroup = "room"
        case channelStore = "channel-store"
        case playerStore = "store"
    }

    struct Request {
        let extensionName: String
        let extensionDescription: String
        let kind: Kind
        let name: String
    }

    /// Test seam: how the user is asked. Returns whether they allowed it.
    var ask: (Request) async -> Bool = RelayConsent.askWithAlert

    private var declined: Set<String> = []
    private var pending: [String: Task<Bool, Never>] = [:]

    private static func defaultsKey(_ id: String) -> String { "relay.consent.\(id)" }

    /// What the extension has been allowed, as `<kind>:<name>`.
    func granted(_ id: String) -> [String] { UserDefaults.standard.stringArray(forKey: Self.defaultsKey(id)) ?? [] }

    /// Returns when the user has allowed this extension to use `name`; throws when they haven't.
    func require(_ id: String, _ kind: Kind, _ name: String) async throws {
        let item = "\(kind.rawValue):\(name)"
        if granted(id).contains(item) { return }
        let token = "\(id)|\(item)"
        guard !declined.contains(token) else { throw RelayManager.RelayError(Self.declinedMessage(kind, name)) }
        // Several pages of one extension can ask at once; they share one prompt.
        let task: Task<Bool, Never>
        if let existing = pending[token] {
            task = existing
        } else {
            let info = ExtensionManager.shared.info(id)
            let request = Request(extensionName: info?.displayName ?? id, extensionDescription: info?.manifest?.description ?? "",
                                  kind: kind, name: name)
            let ask = self.ask
            task = Task { @MainActor in await ask(request) }
            pending[token] = task
        }
        let allowed = await task.value
        pending[token] = nil
        if allowed {
            var list = granted(id)
            if !list.contains(item) { list.append(item) }
            UserDefaults.standard.set(list, forKey: Self.defaultsKey(id))
        } else {
            declined.insert(token)
            throw RelayManager.RelayError(Self.declinedMessage(kind, name))
        }
    }

    /// Forgets every answer for an extension (on uninstall).
    func forget(_ id: String) {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(id))
        declined = declined.filter { !$0.hasPrefix("\(id)|") }
    }

    private static func what(_ kind: Kind, _ name: String) -> String {
        switch kind {
        case .roomGroup: return "the room group \u{201C}\(name)\u{201D}"
        case .channelStore: return "the shared store \u{201C}\(name)\u{201D}"
        case .playerStore: return "its own store \u{201C}\(name)\u{201D}"
        }
    }

    private static func declinedMessage(_ kind: Kind, _ name: String) -> String {
        "The user didn\u{2019}t allow \(what(kind, name)) on the relay."
    }

    static func askWithAlert(_ request: Request) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow \u{201C}\(request.extensionName)\u{201D} to use \(what(request.kind, request.name)) on the relay?"
        let reach: String
        switch request.kind {
        case .roomGroup: reach = "Anyone who knows the name can join its rooms and read what is sent there"
        case .channelStore: reach = "Anyone who knows the name can read and write this store"
        case .playerStore: reach = "Public values in it can be read by anyone who knows the name"
        }
        var details = request.extensionDescription.isEmpty ? "" : "\(request.extensionDescription)\n\n"
        details += "This goes through Satellite\u{2019}s shared relay, a third-party online service. \(reach), and the relay\u{2019}s operator can read it all. Don\u{2019}t allow it for anything that carries case or customer data."
        alert.informativeText = details
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don\u{2019}t Allow")
        // Background scripts can ask while no window is in front; a sheet no one can see would never be answered.
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }
}
