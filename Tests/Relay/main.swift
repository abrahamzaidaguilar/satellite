// Checks for the relay features extensions get beyond pub/sub (satellite.relay.rooms, .stores, .notifications and
// .identity), run by scripts/test-relay.sh. Offline only: frames are built and parsed here, nothing is sent to the
// relay. It covers the manifest permissions, name and size limits, push parsing, the signed store bodies, the
// fields notifications pass on, and the per-name consent prompt (with a stand-in for the alert).
import AppKit
import CryptoKit

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS: \(what)" : "FAIL: \(what)"); if !ok { failures += 1 } }
func throwsError(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }

// MARK: Permissions in manifest.json

func manifest(_ permissions: [String]) throws -> ExtensionManifest {
    let json: [String: Any] = ["name": "Relay Test", "version": "1.0.0", "author": "Tests", "description": "Checks the relay.",
                               "background": "background.js", "permissions": permissions]
    return try ExtensionManifest.parse(try JSONSerialization.data(withJSONObject: json), folderName: "relay-test")
}
let parsed = try? manifest(["relay-rooms", "relay-stores", "relay-notifications"])
check(parsed?.permissions == [.relayRooms, .relayStores, .relayNotifications], "relay-rooms, relay-stores and relay-notifications are manifest permissions")
check(throwsError { _ = try manifest(["rooms"]) }, "an unknown permission is still refused")
check(ExtensionPermission.allCases.allSatisfy { !$0.summary.isEmpty }, "every permission has a summary for the install screen")
check([ExtensionPermission.relayRooms, .relayStores, .relayNotifications].allSatisfy { $0.summary.contains("third-party") },
      "the new permissions say the relay is a third-party service")

// MARK: Names and sizes

MainActor.assumeIsolated {
    check(!throwsError { try RelayManager.checkRoom("myext.lobby", "room-1_A") }, "a room group and name of letters, digits and ._- are accepted")
    check(throwsError { try RelayManager.checkRoom(String(repeating: "g", count: 65), "r") }, "room groups are at most 64 characters")
    check(!throwsError { try RelayManager.checkRoom(String(repeating: "g", count: 64), String(repeating: "r", count: 48)) }, "\u{2026}and rooms up to 48")
    check(throwsError { try RelayManager.checkRoom("g", String(repeating: "r", count: 49)) }, "room names are at most 48 characters")
    check(throwsError { try RelayManager.checkRoom("my ext", "r") } && throwsError { try RelayManager.checkRoom("g", "a/b") }
          && throwsError { try RelayManager.checkRoom("g@1.0.0", "r") }, "spaces, slashes and @ are refused in room ids (they would change the route)")
    check(throwsError { try RelayManager.checkRoom("satadm.abc", "r") } && throwsError { try RelayManager.checkStore("satadm", "k") },
          "names under device management\u{2019}s satadm prefix are refused")
    check(!throwsError { try RelayManager.checkStore("myext.scores@1", "best_time-2") }, "store channels and keys allow ._-@")
    check(throwsError { try RelayManager.checkStore(".myext", "k") } && throwsError { try RelayManager.checkStore("myext.", "k") }
          && throwsError { try RelayManager.checkStore("my..ext", "k") } && throwsError { try RelayManager.checkStore("myext", "a..b") },
          "store names with leading, trailing or doubled dots are refused")
    check(throwsError { try RelayManager.checkStore(String(repeating: "c", count: 129), "k") } && throwsError { try RelayManager.checkStore("c", "a/b") },
          "store names are at most 128 characters and have no slashes")
    check(throwsError { try RelayManager.checkValue("") } && !throwsError { try RelayManager.checkValue("x") }
          && !throwsError { try RelayManager.checkValue(String(repeating: "x", count: 4096)) } && throwsError { try RelayManager.checkValue(String(repeating: "x", count: 4097)) },
          "store values are 1 byte to 4 KB")
    check(throwsError { try RelayManager.checkValue(String(repeating: "\u{00e9}", count: 2049)) }, "\u{2026}counted in UTF-8 bytes")
    check(!throwsError { try RelayManager.checkPlayer(String(repeating: "ab", count: 32)) } && throwsError { try RelayManager.checkPlayer(String(repeating: "AB", count: 32)) }
          && throwsError { try RelayManager.checkPlayer("abc") }, "player keys are 64 lowercase hex")
}

// MARK: Frames

func push(kind: UInt8, name: String, sender: [UInt8], payload: String) -> Data {
    var out: [UInt8] = [0x48, 0x4d, 0x04, 0, 0, kind]
    let nameBytes = Array(name.utf8)
    out += [UInt8(nameBytes.count & 0xff), UInt8(nameBytes.count >> 8)]
    out += nameBytes + sender + Array(payload.utf8)
    return Data(out)
}
let senderBytes = [UInt8](repeating: 0xab, count: 32)
for kind: UInt8 in [2, 3, 4, 5, 6] {
    let parsedPush = SatellaConnection.parse(push(kind: kind, name: "myext.lobby.r1@1.0.0", sender: senderBytes, payload: "hi"))?.push
    check(parsedPush?.kind == kind && parsedPush?.name == "myext.lobby.r1@1.0.0" && parsedPush?.sender == String(repeating: "ab", count: 32)
          && parsedPush?.payload == "hi", "push kind \(kind) is parsed with its name, sender and payload")
}
let anonymous = SatellaConnection.parse(push(kind: 6, name: "", sender: [UInt8](repeating: 0, count: 32), payload: "{}"))?.push
check(anonymous?.sender == "", "an all-zero sender is reported as no sender")
let rawReply = SatellaConnection.parse(Data([0x48, 0x4d, 0x01, 200, 0] + Array("stored".utf8)))?.reply
check(rawReply?.status == 200 && rawReply?.data == Data("stored".utf8) && rawReply?.body == "",
      "a type-1 reply keeps its bytes for store reads (its text body stays empty, as before)")
check(SatellaConnection.members(Data("{\"members\":[\"AA\",\"bb\"]}".utf8)) == ["aa", "bb"] && SatellaConnection.members(Data("oops".utf8)).isEmpty,
      "a join reply\u{2019}s member list is read (lowercased), and junk gives no members")

// MARK: Stores

MainActor.assumeIsolated {
    let keys = Management.Keys.create()
    let value = Data("hello".utf8)
    let body = (try? RelayManager.signed(value, keys)) ?? Data()
    check(body.count == 64 + value.count && body.suffix(value.count) == value
          && keys.signing.publicKey.isValidSignature(body.prefix(64), for: value),
          "a store write is the 64-byte Ed25519 signature of the value, then the value")
    check((try? RelayManager.storeValue(.init(status: 404, body: Data("Not found".utf8)))) == .some(nil), "404 reads as no value (null)")
    check((try? RelayManager.storeValue(.init(status: 200, body: Data("v".utf8)))) == "v", "200 reads as the value")
    check(throwsError { _ = try RelayManager.storeValue(.init(status: 200, body: Data())) },
          "an empty 200 is an error, not an empty value (values are never empty)")
    check(throwsError { _ = try RelayManager.storeValue(.init(status: 403, body: Data("bad signature".utf8))) }, "other statuses are errors")
}

// MARK: Notifications

MainActor.assumeIsolated {
    let fields = RelayManager.notificationFields("{\"prefix\":\"[Server]\",\"message\":\"Back soon\",\"suffix\":\"!\",\"duration\":5,\"token\":\"secret\"}")
    check(fields["prefix"] as? String == "[Server]" && fields["message"] as? String == "Back soon" && fields["suffix"] as? String == "!"
          && (fields["duration"] as? NSNumber)?.doubleValue == 5 && fields["token"] == nil && fields.count == 4,
          "a notification passes on prefix, message, suffix and duration and nothing else")
    let plain = RelayManager.notificationFields("just text")
    check(plain["message"] as? String == "just text" && plain["duration"] is NSNull, "a notification that isn\u{2019}t JSON arrives as its message")
}

// MARK: Consent per room group and store

var done = false
Task { @MainActor in
    let consent = RelayConsent.shared
    let id = "relay-test-\(UUID().uuidString.prefix(8).lowercased())"
    var asked: [RelayConsent.Request] = []
    var answer = true
    consent.ask = { request in
        asked.append(request)
        try? await Task.sleep(nanoseconds: 50_000_000)
        return answer
    }
    do {
        async let first: Void = consent.require(id, .roomGroup, "myext.lobby")
        async let second: Void = consent.require(id, .roomGroup, "myext.lobby")
        _ = try await (first, second)
        check(asked.count == 1 && asked[0].kind == .roomGroup && asked[0].name == "myext.lobby",
              "two pages asking for the same room group at once share one prompt")
        try await consent.require(id, .roomGroup, "myext.lobby")
        check(asked.count == 1 && consent.granted(id) == ["room:myext.lobby"], "Allow is remembered, so it isn\u{2019}t asked again")
    } catch { check(false, "allowed consent threw \(error)") }

    answer = false
    var refused = false
    do { try await consent.require(id, .channelStore, "myext.lobby") } catch { refused = true }
    check(refused && asked.count == 2 && asked[1].kind == .channelStore, "each kind of name is asked about separately, and Don\u{2019}t Allow refuses the call")
    refused = false
    do { try await consent.require(id, .channelStore, "myext.lobby") } catch { refused = true }
    check(refused && asked.count == 2, "Don\u{2019}t Allow is remembered for the session, so a retrying page doesn\u{2019}t keep asking")

    answer = true
    do { try await consent.require("other-\(id)", .roomGroup, "myext.lobby") } catch {}
    check(asked.count == 3, "consent is per extension: another extension is asked about the same group")
    consent.forget("other-\(id)")

    consent.forget(id)
    check(consent.granted(id).isEmpty, "uninstalling forgets the answers")
    do { try await consent.require(id, .channelStore, "myext.lobby") } catch {}
    check(asked.count == 4, "\u{2026}including Don\u{2019}t Allow, so a reinstall is asked again")
    consent.forget(id)
    done = true
}
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

print(failures == 0 ? "\nAll relay checks passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
