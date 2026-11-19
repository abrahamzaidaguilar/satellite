import Foundation

/// Satellite's own front to the Satella relay for extensions. Instead of each extension shipping a copy of
/// satella.js and opening its own WebSocket to the relay, it calls `satellite.relay` (gated by the `relay`
/// permission) and Satellite keeps one native connection per extension (via `SatellaConnection`), so the relay is
/// reached in one place that Satellite controls.
///
/// Each extension gets its own persistent player identity, so its messages are attributed to it (the `sender` on
/// inbound messages) and its channels are its own. Inbound messages are delivered to the extension's pages and
/// background with `satellite.relay.onMessage` via the existing emit path (type `relay`).
///
/// The same connection and identity carry Satella's rooms (`relay-rooms`), its channel and player stores
/// (`relay-stores`) and its server notifications (`relay-notifications`). Joining a room group or using a store
/// also asks the user once per name (`RelayConsent`), as Ghostship does; store values are signed here with the
/// extension's key, which never reaches JavaScript.
@MainActor
final class RelayManager {
    static let shared = RelayManager()

    /// Satella channel ids, matching satella.js: 1–128 of letters, digits, dot, underscore, hyphen.
    static let channelPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,128}$")
    static let maxMessageBytes = 100_000

    // Ghostship's limits for rooms and stores (AGENTS.md, section 5).
    static let roomGroupPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,64}$")
    static let roomNamePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,48}$")
    static let storeNamePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._@-]{1,128}$")
    static let playerKeyPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
    static let maxRoomMessageBytes = 64 * 1024
    static let roomMessagesPerSecond = 60
    static let maxStoreValueBytes = 4096
    /// Device management's channels (`satadm.…`); the new features refuse names under it.
    static let reservedPrefix = "satadm"

    enum StoreScope: String { case `private`, `public` }

    private struct Conn {
        let connection: SatellaConnection
        var retry = 2.0
        var reconnecting = false
        var connected = false
    }
    private var conns: [String: Conn] = [:]
    private var identities: [String: Management.Keys] = [:]

    /// Per extension, the rooms it is in (`<group>.<room>` -> its parts) and the other members it knows of.
    private var rooms: [String: [String: (group: String, room: String)]] = [:]
    private var members: [String: [String: Set<String>]] = [:]
    /// Per extension and room, when its recent room messages were sent (for the 60-a-second limit).
    private var sent: [String: [Date]] = [:]

    struct RelayError: LocalizedError { let errorDescription: String? ; init(_ m: String) { errorDescription = m } }

    /// The extension's own sender key (hex), so it can recognize its own messages among those it receives.
    func identityHex(for id: String) -> String { keys(for: id).signHex }

    func subscribe(_ id: String, channel: String) async throws {
        try Self.check(channel)
        let conn = try await connection(for: id)
        try await conn.subscribe(channel)
    }

    func unsubscribe(_ id: String, channel: String) async {
        guard let conn = conns[id]?.connection else { return }
        await conn.unsubscribe(channel)
    }

    func send(_ id: String, channel: String, text: String) async throws {
        try Self.check(channel)
        guard text.utf8.count <= Self.maxMessageBytes else { throw RelayError("Relay messages are limited to 100 KB.") }
        let conn = try await connection(for: id)
        await conn.send(text, on: channel)
    }

    // MARK: Rooms

    /// Joins `<group>.<room>` (asking the user about the group the first time) and returns the other members.
    func join(_ id: String, group: String, room: String) async throws -> [String: Any] {
        try Self.checkRoom(group, room)
        try await RelayConsent.shared.require(id, .roomGroup, group)
        let conn = try await connection(for: id)
        let key = "\(group).\(room)"
        let listed = try await conn.join(key)
        let others = Set(listed).subtracting([identityHex(for: id)])
        if rooms[id]?[key] != nil {
            reconcile(id, key, others)   // already in it: report the difference as joins and leaves
        } else {
            rooms[id, default: [:]][key] = (group, room)
            members[id, default: [:]][key] = others
        }
        return ["group": group, "room": room, "members": others.sorted()]
    }

    func leave(_ id: String, group: String, room: String) async throws {
        try Self.checkRoom(group, room)
        let key = "\(group).\(room)"
        rooms[id]?[key] = nil
        members[id]?[key] = nil
        sent["\(id)|\(key)"] = nil
        await conns[id]?.connection.leave(key)
    }

    /// Sends to the room's other members, or to one of them. Only in a room this extension has joined.
    func sendToRoom(_ id: String, group: String, room: String, text: String, to member: String?) async throws {
        try Self.checkRoom(group, room)
        let key = "\(group).\(room)"
        guard rooms[id]?[key] != nil, let conn = conns[id]?.connection else {
            throw RelayError("Join the room before sending to it.")
        }
        if let member { try Self.checkPlayer(member) }
        guard text.utf8.count <= Self.maxRoomMessageBytes else { throw RelayError("Room messages are limited to 64 KB.") }
        let now = Date()
        var recent = (sent["\(id)|\(key)"] ?? []).filter { now.timeIntervalSince($0) < 1 }
        guard recent.count < Self.roomMessagesPerSecond else { throw RelayError("Room messages are limited to 60 a second.") }
        recent.append(now)
        sent["\(id)|\(key)"] = recent
        await conn.send(text, room: key, to: member)
    }

    /// The other members this extension knows to be in a room it has joined.
    func roomMembers(_ id: String, group: String, room: String) throws -> [String] {
        try Self.checkRoom(group, room)
        guard let known = members[id]?["\(group).\(room)"] else { throw RelayError("Not in that room.") }
        return known.sorted()
    }

    private func roomEvent(_ id: String, _ event: SatellaConnection.RoomEvent) {
        guard let names = rooms[id]?[event.room] else { return }
        let me = identityHex(for: id)
        switch event.kind {
        case .message, .direct:
            guard event.sender != me else { return }
            ExtensionManager.shared.emit(id, type: "roomMessage", arguments: [[
                "group": names.group, "room": names.room, "sender": event.sender, "text": event.text,
                "direct": event.kind == .direct,
            ]])
        case .join:
            guard !event.sender.isEmpty, event.sender != me,
                  members[id]?[event.room]?.insert(event.sender).inserted == true else { return }
            emitMember(id, "roomJoin", names, event.sender)
        case .leave:
            guard members[id]?[event.room]?.remove(event.sender) != nil else { return }
            emitMember(id, "roomLeave", names, event.sender)
        case .members:
            reconcile(id, event.room, Set(event.members).subtracting([me]))
        }
    }

    /// Brings the known members of a room in line with `now`, reporting who left and who arrived.
    private func reconcile(_ id: String, _ key: String, _ now: Set<String>) {
        guard let names = rooms[id]?[key] else { return }
        let before = members[id]?[key] ?? []
        members[id, default: [:]][key] = now
        for member in before.subtracting(now).sorted() { emitMember(id, "roomLeave", names, member) }
        for member in now.subtracting(before).sorted() { emitMember(id, "roomJoin", names, member) }
    }

    /// A dropped socket is in no rooms: everyone has left as far as the extension can tell, until the rejoin
    /// (`SatellaConnection.start`) reports who is there again.
    private func everyoneLeft(_ id: String) {
        for key in (members[id] ?? [:]).keys { reconcile(id, key, []) }
    }

    private func emitMember(_ id: String, _ type: String, _ names: (group: String, room: String), _ member: String) {
        ExtensionManager.shared.emit(id, type: type, arguments: [["group": names.group, "room": names.room, "member": member]])
    }

    // MARK: Stores

    /// A value in a store shared by everyone on `channel`. nil when there is none.
    func channelStoreGet(_ id: String, channel: String, key: String) async throws -> String? {
        try Self.checkStore(channel, key)
        try await RelayConsent.shared.require(id, .channelStore, channel)
        let conn = try await connection(for: id)
        let response = try await conn.call("/v1/channel-store/\(channel)/\(key)/get")
        return try Self.storeValue(response)
    }

    func channelStoreSet(_ id: String, channel: String, key: String, value: String) async throws {
        try Self.checkStore(channel, key)
        try Self.checkValue(value)
        try await RelayConsent.shared.require(id, .channelStore, channel)
        let conn = try await connection(for: id)
        let keys = keys(for: id)
        let body = try Self.signed(Data(value.utf8), keys)
        let response = try await conn.call("/v1/channel-store/\(keys.signHex)/\(channel)/\(key)/set", body: body)
        try Self.expectOK(response)
    }

    func channelStoreRemove(_ id: String, channel: String, key: String) async throws {
        try Self.checkStore(channel, key)
        try await RelayConsent.shared.require(id, .channelStore, channel)
        let conn = try await connection(for: id)
        let keys = keys(for: id)
        let body = try keys.sign(Data("\(channel)/\(key)".utf8))
        let response = try await conn.call("/v1/channel-store/\(keys.signHex)/\(channel)/\(key)/delete", body: body)
        try Self.expectOK(response)
    }

    /// A value in a player's store: this extension's own by default, or another player's `public` one.
    func playerStoreGet(_ id: String, channel: String, scope: StoreScope, key: String, player: String?) async throws -> String? {
        try Self.checkStore(channel, key)
        let me = identityHex(for: id)
        let owner = player ?? me
        try Self.checkPlayer(owner)
        guard scope == .public || owner == me else { throw RelayError("Only the owner can read a private store value.") }
        try await RelayConsent.shared.require(id, .playerStore, channel)
        let conn = try await connection(for: id)
        let response = try await conn.call("/v1/store/\(owner)/\(channel)/\(scope.rawValue)/\(key)/get")
        return try Self.storeValue(response)
    }

    func playerStoreSet(_ id: String, channel: String, scope: StoreScope, key: String, value: String) async throws {
        try Self.checkStore(channel, key)
        try Self.checkValue(value)
        try await RelayConsent.shared.require(id, .playerStore, channel)
        let conn = try await connection(for: id)
        let keys = keys(for: id)
        let body = try Self.signed(Data(value.utf8), keys)
        let response = try await conn.call("/v1/store/\(keys.signHex)/\(channel)/\(scope.rawValue)/\(key)/set", body: body)
        try Self.expectOK(response)
    }

    func playerStoreRemove(_ id: String, channel: String, scope: StoreScope, key: String) async throws {
        try Self.checkStore(channel, key)
        try await RelayConsent.shared.require(id, .playerStore, channel)
        let conn = try await connection(for: id)
        let keys = keys(for: id)
        let body = try keys.sign(Data("\(channel)/\(scope.rawValue)/\(key)".utf8))
        let response = try await conn.call("/v1/store/\(keys.signHex)/\(channel)/\(scope.rawValue)/\(key)/delete", body: body)
        try Self.expectOK(response)
    }

    /// The set body: the 64-byte Ed25519 signature of the value, then the value.
    static func signed(_ value: Data, _ keys: Management.Keys) throws -> Data {
        var body = try keys.sign(value)
        body.append(value)
        return body
    }

    static func storeValue(_ response: SatellaConnection.Response) throws -> String? {
        if response.status == 404 { return nil }
        try expectOK(response)
        // Values are at least 1 byte, so an empty 200 means the relay didn't send the value back.
        guard !response.body.isEmpty else { throw RelayError("The relay answered without the stored value.") }
        return String(decoding: response.body, as: UTF8.self)
    }

    private static func expectOK(_ response: SatellaConnection.Response) throws {
        guard response.status == 200 else {
            let detail = String(decoding: response.body, as: UTF8.self)
            throw RelayError("The relay refused the store request (\(response.status)\(detail.isEmpty ? "" : ": \(detail)")).")
        }
    }

    // MARK: Notifications

    func subscribeNotifications(_ id: String) async throws {
        let conn = try await connection(for: id)
        try await conn.subscribeNotifications()
    }

    func unsubscribeNotifications(_ id: String) async {
        await conns[id]?.connection.unsubscribeNotifications()
    }

    /// Passes on the documented fields of a notification push (`{prefix, message, suffix, duration}`) and nothing else.
    static func notificationFields(_ payload: String) -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
        guard let json else { return ["prefix": "", "message": payload, "suffix": "", "duration": NSNull()] }
        let text = { (key: String) -> String in
            if let value = json[key] as? String { return value }
            if let value = json[key] as? NSNumber { return value.stringValue }
            return ""
        }
        return ["prefix": text("prefix"), "message": text("message"), "suffix": text("suffix"),
                "duration": (json["duration"] as? NSNumber) ?? NSNull()]
    }

    /// Drops an extension's relay connection (on uninstall/disable).
    func stop(_ id: String) {
        if let conn = conns[id]?.connection { Task { await conn.stop() } }
        conns[id] = nil
        rooms[id] = nil
        members[id] = nil
        sent = sent.filter { !$0.key.hasPrefix("\(id)|") }
    }

    /// Closes relay connections for extensions that are no longer active.
    func prune(keeping active: Set<String>) {
        for id in conns.keys where !active.contains(id) { stop(id) }
    }

    // MARK: Connection per extension

    private func connection(for id: String) async throws -> SatellaConnection {
        if let existing = conns[id] {
            // Revive a connection that went dead and isn't already being retried (e.g. an earlier cold start that
            // failed while the relay was unreachable). Channels the caller adds are replayed when it reconnects.
            if !existing.connected, !existing.reconnecting { reconnect(id) }
            return existing.connection
        }
        let connection = SatellaConnection(
            host: SatellaConnection.defaultHost, identity: keys(for: id), channels: [],
            onRelay: { [weak self] relay in
                Task { @MainActor in self?.deliver(id, relay) }
            },
            onClose: { [weak self] in
                Task { @MainActor in self?.everyoneLeft(id); self?.reconnect(id) }
            },
            onRoom: { [weak self] event in
                Task { @MainActor in self?.roomEvent(id, event) }
            },
            onNotification: { payload in
                Task { @MainActor in
                    ExtensionManager.shared.emit(id, type: "relayNotification", arguments: [Self.notificationFields(payload)])
                }
            })
        conns[id] = Conn(connection: connection)
        do {
            try await connection.start()
            conns[id]?.connected = true
            conns[id]?.retry = 2.0
        } catch {
            // Don't leave a dead connection: keep retrying in the background so it heals on its own, then report
            // this first failure to the caller (the extension may also retry, which revives it via the branch above).
            reconnect(id)
            throw error
        }
        return connection
    }

    private func deliver(_ id: String, _ relay: SatellaConnection.Relay) {
        ExtensionManager.shared.emit(id, type: "relay", arguments: [[
            "channel": relay.channel, "sender": relay.sender, "text": relay.text,
        ]])
    }

    /// Reconnects after a dropped socket, backing off, and re-subscribes (start() replays the channel list).
    private func reconnect(_ id: String) {
        guard var conn = conns[id], !conn.reconnecting else { return }
        conn.reconnecting = true
        conn.connected = false
        conns[id] = conn
        let delay = conn.retry
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard conns[id] != nil else { return }   // stopped meanwhile
            do {
                try await conn.connection.start()
                conns[id]?.reconnecting = false
                conns[id]?.connected = true
                conns[id]?.retry = 2.0
            } catch {
                conns[id]?.reconnecting = false
                conns[id]?.retry = min(delay * 2, 60)
                reconnect(id)
            }
        }
    }

    // MARK: Identity

    private func keys(for id: String) -> Management.Keys {
        if let keys = identities[id] { return keys }
        let defaultsKey = "relay.identity.\(id)"
        if let text = UserDefaults.standard.string(forKey: defaultsKey), let data = Data(base64Encoded: text),
           let stored = try? JSONDecoder().decode(Management.Keys.Stored.self, from: data), let keys = try? Management.Keys(stored) {
            identities[id] = keys
            return keys
        }
        let keys = Management.Keys.create()
        if let data = try? JSONEncoder().encode(keys.stored) {
            UserDefaults.standard.set(data.base64EncodedString(), forKey: defaultsKey)
        }
        identities[id] = keys
        return keys
    }

    static func checkRoom(_ group: String, _ room: String) throws {
        guard matches(roomGroupPattern, group) else {
            throw RelayError("A room group is 1\u{2013}64 characters of letters, digits, \u{201C}.\u{201D}, \u{201C}_\u{201D} or \u{201C}-\u{201D}.")
        }
        guard matches(roomNamePattern, room) else {
            throw RelayError("A room name is 1\u{2013}48 characters of letters, digits, \u{201C}.\u{201D}, \u{201C}_\u{201D} or \u{201C}-\u{201D}.")
        }
        try checkNotReserved(group)
    }

    static func checkStore(_ channel: String, _ key: String) throws {
        for (what, name) in [("store channel", channel), ("store key", key)] {
            guard matches(storeNamePattern, name), !name.hasPrefix("."), !name.hasSuffix("."), !name.contains("..") else {
                throw RelayError("A \(what) is 1\u{2013}128 characters of letters, digits, \u{201C}.\u{201D}, \u{201C}_\u{201D}, \u{201C}-\u{201D} or \u{201C}@\u{201D}, with no leading, trailing or doubled dots.")
            }
        }
        try checkNotReserved(channel)
    }

    static func checkValue(_ value: String) throws {
        let size = value.utf8.count
        guard size >= 1, size <= maxStoreValueBytes else { throw RelayError("Store values are 1 byte to 4 KB of text.") }
    }

    static func checkPlayer(_ key: String) throws {
        guard matches(playerKeyPattern, key) else { throw RelayError("A player key is 64 lowercase hex characters.") }
    }

    private static func checkNotReserved(_ name: String) throws {
        guard !name.lowercased().hasPrefix(reservedPrefix) else {
            throw RelayError("Names starting with \u{201C}\(reservedPrefix)\u{201D} belong to device management.")
        }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func check(_ channel: String) throws {
        let range = NSRange(channel.startIndex..., in: channel)
        guard channelPattern.firstMatch(in: channel, range: range) != nil else {
            throw RelayError("A relay channel is 1\u{2013}128 characters of letters, digits, \u{201C}.\u{201D}, \u{201C}_\u{201D} or \u{201C}-\u{201D}.")
        }
    }
}
