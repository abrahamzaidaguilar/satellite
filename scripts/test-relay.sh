#!/bin/bash
# Checks the relay features extensions get beyond pub/sub (satellite.relay.rooms, .stores, .notifications, .identity):
# the Swift side offline (no traffic to the relay), and that the injected `satellite` API still parses as JavaScript.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== Swift side (offline) =="
swift build >/dev/null   # builds SwiftTerm, whose objects the checks link against
BIN="$(swift build --show-bin-path)"
FILES=$(ls Sources/Satellite/*.swift | grep -v '/main.swift$')
# shellcheck disable=SC2086
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14 -I "$BIN/Modules" \
  $FILES Tests/Relay/main.swift "$BIN"/SwiftTerm.build/*.o -o "$WORK/checks"
SATELLITE_HOME="$WORK/home" "$WORK/checks"

echo "== injected API (JavaScript) =="
# The bridge part of ExtensionManager.buildSource, with Swift interpolations swapped for values, must parse.
python3 - "$WORK/bridge.js" <<'PY'
import sys
source = open("Sources/Satellite/ExtensionManager.swift").read()
start = source.index('let bridge = isolated ? """') + len('let bridge = isolated ? """')
js = source[start:source.index('""" : ""', start)]
def strip(text):   # replace each \( ... ) (parentheses may nest) with a placeholder value
    out, i = [], 0
    while i < len(text):
        if text.startswith("\\(", i):
            depth, j = 1, i + 2
            while depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            out.append('"x"')
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)
js = strip(js).replace("\\\\", "\\")
names = ["relay.rooms.join", "relay.rooms.leave", "relay.rooms.send", "relay.rooms.members",
         "relay.stores.channel.get", "relay.stores.channel.set", "relay.stores.channel.remove",
         "relay.stores.player.get", "relay.stores.player.set", "relay.stores.player.remove",
         "relay.notifications.subscribe", "relay.notifications.unsubscribe"]
native = open("Sources/Satellite/ExtensionManager.swift").read()
missing = [n for n in names if "'%s'" % n not in js or '"%s"' % n not in native]
if missing: sys.exit("methods missing from the wrapper or the bridge: %s" % ", ".join(missing))
open(sys.argv[1], "w").write("(function () {\n" + js + "\n})();\n")
PY
node --check "$WORK/bridge.js"
echo "  ok  the satellite API wrapper parses, and every new method is on both sides"

echo "All relay checks passed."
