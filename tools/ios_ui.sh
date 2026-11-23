#!/bin/bash
# iOS Simulator UI test: builds a Debug app, pairs it with tools/fake_android.py through the real
# protocol, screenshots every screen (light + dark) and checks the app used the API.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/ios-ui-out}"
mkdir -p "$OUT"
BUNDLE=app.simbridge.ios
FAIL=0
pass() { echo "- PASS $1" | tee -a "$OUT/report.md"; }
fail() { echo "- FAIL $1" | tee -a "$OUT/report.md"; FAIL=1; }
echo "# iOS Simulator UI test" > "$OUT/report.md"

cd "$ROOT/ios"
xcodegen generate >/dev/null
xcodebuild -project SIMBridge.xcodeproj -target SIMBridge -configuration Debug -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build > "$OUT/build.log" 2>&1
APP="$ROOT/ios/build/Debug-iphonesimulator/SIMBridge.app"
if [ -d "$APP" ]; then pass "Debug simulator build"; else fail "Debug simulator build"; grep -E "error:" "$OUT/build.log" | head -40; exit 1; fi

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=[x for r,l in d.items() if "iOS" in r for x in l if x["name"].startswith("iPhone 16") and "Plus" not in x["name"] and "Pro" not in x["name"]]
c=c or [x for r,l in d.items() if "iOS" in r for x in l if x["name"].startswith("iPhone")]
print(c[-1]["udid"])')
echo "Simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"

PAY=/tmp/simbridge_pair.txt
SLOG="$OUT/fake_android_log.json"
FLAG=/tmp/simbridge_call
rm -f "$FLAG"
python3 "$ROOT/tools/fake_android.py" --payload-out "$PAY" --log "$SLOG" --call-flag "$FLAG" > "$OUT/fake_android.txt" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for i in $(seq 1 20); do [ -s "$PAY" ] && break; sleep 0.5; done

shot() { sleep "$2"; xcrun simctl io "$UDID" screenshot "$OUT/$1.png" >/dev/null 2>&1; sips -Z 1300 "$OUT/$1.png" >/dev/null 2>&1; }
launch() { xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null; sleep 0.5; xcrun simctl launch "$UDID" $BUNDLE -SIMBridgeTestMode YES "$@" >/dev/null; }
crashed() { ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i simbridge; }

run_round() {  # $1 = suffix
  local s="$1"
  launch -SIMBridgeTab home;      shot "10_home$s" 5
  launch -SIMBridgeTab messages;  shot "11_messages$s" 4
  launch -SIMBridgeTab thread;    shot "12_conversation$s" 5
  launch -SIMBridgeTab phone;     shot "13_keypad$s" 4
  launch -SIMBridgeTab recents;   shot "14_recents$s" 4
  launch -SIMBridgeTab contacts;  shot "15_contacts$s" 4
  launch -SIMBridgeTab settings;  shot "16_settings$s" 4
  touch "$FLAG"
  launch -SIMBridgeTab home;      shot "17_incoming_call$s" 6
  rm -f "$FLAG"
}

xcrun simctl ui "$UDID" appearance light
launch -SIMBridgeReset YES;                                   shot 01_onboarding 4
launch -SIMBridgeReset YES -SIMBridgeTestPair "$(cat "$PAY")"; shot 02_pair_confirm 4
sleep 8;                                                       shot 03_after_pairing 1
run_round ""
xcrun simctl ui "$UDID" appearance dark
run_round "_dark"
xcrun simctl ui "$UDID" appearance light

has() { python3 -c "import json,sys; l=json.load(open('$SLOG')); sys.exit(0 if any(e['kind']==sys.argv[1] and (len(sys.argv)<3 or e['detail']==sys.argv[2]) for e in l) else 1)" "$@"; }
has pair_request && pass "pairing request with verification code" || fail "pairing request"
has paired && pass "pairing completed (iOS accepted credentials)" || fail "pairing completed"
has ready && pass "iOS reconnected with device key (CryptoKit <-> AES-GCM interop)" || fail "device auth"
for r in sync threads messages contacts calls; do has request "$r" && pass "iOS requested $r" || fail "iOS requested $r"; done
has bad_auth && fail "server saw a bad auth frame" || pass "no bad auth frames"
has error && fail "server errors (see fake_android_log.json)" || pass "no protocol errors"
if [ -n "$(crashed)" ]; then fail "app crashed: $(crashed)"; else pass "no crash reports"; fi
echo "exit $FAIL"
exit $FAIL
