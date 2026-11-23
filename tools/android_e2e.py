#!/usr/bin/env python3
"""End-to-end test of the Android agent on an emulator, acting exactly like the iPhone app.

Covers: auto-start, QR pairing + 4-digit code + approval, device auth, every request type,
live SMS (receive + send with delivery status), incoming call (answer / reject / missed),
outgoing call, rejection of unknown devices and tampered frames, crash detection.
Writes screenshots, report.md and results.json to --out. Exit code 1 if a required check fails.
"""
import argparse
import faulthandler
import json
import os
import re
import socket
import subprocess
import sys
import time
import traceback
import uuid
import xml.etree.ElementTree as ET

import websocket  # websocket-client

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protocol as P  # noqa: E402

PKG = "app.simbridge.android"
OUT = "out"
results = []


def check(name, ok, detail="", required=True):
    results.append({"name": name, "ok": bool(ok), "required": required, "detail": str(detail)[:600]})
    mark = "PASS" if ok else ("FAIL" if required else "WARN")
    print(f"[{mark}] {name} {('- ' + str(detail)[:300]) if detail else ''}", flush=True)
    try:  # keep a partial report even if the run is killed later
        with open(os.path.join(OUT, "partial.json"), "w") as f:
            json.dump(results, f, ensure_ascii=False, indent=1)
    except Exception:
        pass
    return ok


def adb(*args, timeout=60):
    return subprocess.run(["adb", *args], capture_output=True, text=True, timeout=timeout)


def shell(cmd, timeout=60):
    return adb("shell", cmd, timeout=timeout).stdout


def screenshot(name):
    data = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True, timeout=30).stdout
    with open(os.path.join(OUT, name + ".png"), "wb") as f:
        f.write(data)


def logcat_test_lines():
    return adb("logcat", "-d", "-s", "SIMBridgeTest:I").stdout.splitlines()


def tap_text(text):
    shell("uiautomator dump /sdcard/ui.xml", timeout=30)
    xml = shell("cat /sdcard/ui.xml")
    try:
        root = ET.fromstring(xml[xml.index("<?xml"):] if "<?xml" in xml else xml)
    except Exception:
        return False
    for node in root.iter("node"):
        if node.get("text") == text or node.get("content-desc") == text:
            m = re.findall(r"\d+", node.get("bounds", ""))
            if len(m) == 4:
                x1, y1, x2, y2 = map(int, m)
                shell(f"input tap {(x1 + x2) // 2} {(y1 + y2) // 2}")
                return True
    return False


class Client:
    """Minimal iPhone-side client: encrypted requests plus an event buffer."""

    def __init__(self, key):
        self.key = key
        self.ws = None
        self.events = []
        self.rid = 0

    def connect(self):
        self.ws = websocket.create_connection("ws://127.0.0.1:8765", timeout=10)

    def send_plain(self, obj):
        self.ws.send(json.dumps(obj))

    def send(self, obj):
        self.ws.send_binary(P.seal(self.key, obj, P.C2S))

    def recv(self, timeout):
        self.ws.settimeout(timeout)
        op, data = self.ws.recv_data()
        if op == websocket.ABNF.OPCODE_TEXT:
            return {"_plain": True, **json.loads(data.decode("utf-8"))}
        if op == websocket.ABNF.OPCODE_BINARY:
            return P.open_frame(self.key, data, P.S2C)
        if op == websocket.ABNF.OPCODE_CLOSE:
            raise ConnectionError("closed")
        return None

    def request(self, t, timeout=20, **params):
        self.rid += 1
        rid = f"r{self.rid}"
        self.send({"t": t, "rid": rid, **params})
        end = time.time() + timeout
        while time.time() < end:
            try:
                m = self.recv(max(0.5, end - time.time()))
            except (websocket.WebSocketTimeoutException, socket.timeout):
                continue
            if m is None:
                continue
            if m.get("rid") == rid and m.get("t") in ("res", "pong"):
                return m
            self.events.append(m)
        raise TimeoutError(f"no response to {t}")

    def wait_event(self, pred, timeout):
        for i, e in enumerate(self.events):
            if pred(e):
                return self.events.pop(i)
        end = time.time() + timeout
        while time.time() < end:
            try:
                m = self.recv(max(0.5, end - time.time()))
            except (websocket.WebSocketTimeoutException, socket.timeout):
                continue
            if m is None:
                continue
            if pred(m):
                return m
            self.events.append(m)
        return None

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


def call_state(state):
    return lambda e: e.get("t") == "call" and e.get("call", {}).get("state") == state


def check_audio_pipeline():
    jar = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "android", "app", "src", "main", "assets", "scrcpy-server.jar")
    adb("push", jar, "/data/local/tmp/simbridge-scrcpy.jar")
    apk_path = shell(f"pm path {PKG}").strip().splitlines()[0].replace("package:", "")
    sid = "1a2b3c4d"
    # Same script as CallAudioRelay.shellScript()
    script = (
        f"CLASSPATH=/data/local/tmp/simbridge-scrcpy.jar app_process / com.genymobile.scrcpy.Server 3.3.4 scid={sid} "
        "log_level=warn video=false audio=true control=false audio_source=voice-call-downlink "
        "audio_codec=raw tunnel_forward=true raw_stream=true cleanup=false "
        "</dev/null >/dev/null 2>/data/local/tmp/simbridge-audio.log &" + chr(10) +
        "SRV=$!" + chr(10) +
        "trap 'kill $SRV 2>/dev/null' EXIT INT TERM HUP" + chr(10) +
        f"CLASSPATH={apk_path} app_process / app.simbridge.android.shell.SocketCat scrcpy_{sid}" + chr(10)
    )
    with open(os.path.join(OUT, "audio_script.sh"), "w") as f:
        f.write(script)
    adb("push", os.path.join(OUT, "audio_script.sh"), "/data/local/tmp/simbridge-audio.sh")
    try:
        p = subprocess.run(["adb", "exec-out", "sh /data/local/tmp/simbridge-audio.sh"], capture_output=True, timeout=10)
        got = len(p.stdout)
    except subprocess.TimeoutExpired as e:
        got = len(e.stdout or b"")
    shell(f"pkill -f 'scid={sid}'; pkill -f SocketCat; true")
    log = shell("cat /data/local/tmp/simbridge-audio.log")
    with open(os.path.join(OUT, "audio_pipeline.txt"), "w") as f:
        f.write(f"bytes={got}" + chr(10) + log)
    bad = any(k in log for k in ("does not match", "Unknown", "Invalid", "ClassNotFound"))
    check("audio pipeline: scrcpy server accepts our arguments/version", not bad, log[-400:])
    check("audio pipeline: call audio bytes flow to the app side", got > 0, f"{got} bytes; {log[-200:]}", required=False)


def setup_device(apk):
    out = adb("install", "-r", "-g", apk, timeout=240)
    check("install debug APK", "Success" in out.stdout, out.stdout + out.stderr)
    perms = ["READ_SMS", "RECEIVE_SMS", "SEND_SMS", "READ_PHONE_STATE", "CALL_PHONE", "ANSWER_PHONE_CALLS",
             "READ_PHONE_NUMBERS", "READ_CALL_LOG", "READ_CONTACTS", "POST_NOTIFICATIONS",
             "BLUETOOTH_ADVERTISE", "BLUETOOTH_CONNECT"]
    for p in perms:
        shell(f"pm grant {PKG} android.permission.{p}")
    shell(f"dumpsys deviceidle whitelist +{PKG}")
    shell("settings put global window_animation_scale 0; settings put global transition_animation_scale 0; "
          "settings put global animator_duration_scale 0")
    adb("logcat", "-c")


def wait_bridge(timeout=40):
    adb("forward", "tcp:8765", "tcp:8765")
    end = time.time() + timeout
    while time.time() < end:
        try:
            ws = websocket.create_connection("ws://127.0.0.1:8765", timeout=3)
            ws.close()
            return True
        except Exception:
            time.sleep(1)
    return False


def pair():
    """Pairs like the iPhone does. Returns (device_id, device_key, server_id)."""
    lines_before = len(logcat_test_lines())
    tapped = tap_text("اتصال آیفون")
    time.sleep(2)
    if tapped:
        screenshot("02_pair_qr")
    pairs = [l for l in logcat_test_lines()[lines_before:] if " PAIR " in l]
    if not pairs:
        shell(f"am broadcast -a {PKG}.TEST_PAIR -p {PKG}")
        time.sleep(1.5)
        pairs = [l for l in logcat_test_lines() if " PAIR " in l]
    check("pairing window opened from UI button", tapped, required=False)
    if not check("pairing QR payload available", pairs, "no PAIR log line"):
        raise RuntimeError("cannot pair")
    offer = P.parse_pair_url(pairs[-1].split(" PAIR ", 1)[1])
    check("QR contains 32-byte key and server id", len(offer["key"]) == 32 and offer["sid"], offer["sid"])
    check("QR lists a reachable LAN address", offer["hosts"], offer["hosts"], required=False)

    c = Client(offer["key"])
    c.connect()
    c.send_plain({"t": "hello", "mode": "pair", "v": 1})
    ch = c.recv(10)
    check("pair: encrypted challenge received", ch and ch.get("t") == "challenge", ch)
    check("pair: challenge server id matches QR", ch.get("sid") == offer["sid"], ch.get("sid"))
    nonce = P.unb64(ch["n"])
    code = P.verification_code(offer["key"], nonce)
    c.send({"t": "auth", "n": ch["n"], "name": "Test iPhone", "model": "iPhone15,2"})
    time.sleep(2.5)
    shown = [l.split(" APPROVAL ", 1)[1].strip() for l in logcat_test_lines() if " APPROVAL " in l]
    check("pair: 4-digit code on Android equals code on iPhone", shown and shown[-1] == code, f"android={shown[-1:]} iphone={code}")
    screenshot("03_pair_approval")
    shell(f"am broadcast -a {PKG}.TEST_APPROVE --ez approve true -p {PKG}")
    m = c.wait_event(lambda e: e.get("t") in ("paired", "denied"), 15)
    ok = m is not None and m.get("t") == "paired"
    check("pair: approved -> device credentials issued", ok, m)
    dev_key = P.unb64(m["key"]) if ok else b""
    check("pair: device key is 32 bytes", len(dev_key) == 32)
    c.close()

    # The QR is single-use: a second pairing attempt must be refused.
    c2 = Client(offer["key"])
    c2.connect()
    c2.send_plain({"t": "hello", "mode": "pair", "v": 1})
    try:
        r = c2.recv(5)
    except Exception as e:
        r = {"error": str(e)}
    check("pair: used QR is refused (pairing_closed)", r and r.get("code") == "pairing_closed", r)
    c2.close()
    return m["id"], dev_key, offer["sid"]


def connect_device(dev_id, key):
    c = Client(key)
    c.connect()
    c.send_plain({"t": "hello", "mode": "dev", "id": dev_id, "v": 1})
    ch = c.recv(10)
    c.send({"t": "auth", "n": ch["n"], "name": "Test iPhone", "model": "iPhone15,2"})
    r = c.wait_event(lambda e: e.get("t") == "ready", 10)
    check("device: authenticated and ready", r is not None, r)
    if r:
        check("device: ready lists hosts and port", isinstance(r.get("hosts"), list) and r.get("port") == 8765, r)
    return c


def run_requests(c):
    t0 = time.time()
    r = c.request("ping", ts=int(time.time() * 1000))
    check("ping/pong", r.get("t") == "pong", f"{int((time.time() - t0) * 1000)} ms")

    r = c.request("sync")
    d = r.get("data", {})
    st = d.get("status", {})
    check("sync: ok", r.get("ok"), r.get("err"))
    check("sync: status has SIM list, battery, device, perms",
          isinstance(st.get("sims"), list) and "battery" in st and "device" in st and "perms" in st, json.dumps(st)[:400])
    check("sync: all permissions granted", st.get("perms") and all(st["perms"].values()), st.get("perms"))
    sims = st.get("sims") or []
    check("antenna: at least one SIM reported", len(sims) >= 1, sims)
    if sims:
        s = sims[0]
        check("antenna: level 0..4 and service state", 0 <= s.get("level", -1) <= 4 and s.get("service") in ("in", "out", "emergency", "off", "unknown"), s)
        check("antenna: in service with signal", s.get("service") == "in" and s.get("level", 0) > 0, s, required=False)
        check("antenna: operator name present", bool(s.get("carrier")), s.get("carrier"), required=False)
    check("sync: call state idle", d.get("call", {}).get("state") == "idle", d.get("call"))
    check("sync: audio state", isinstance(d.get("audio"), dict), d.get("audio"))
    check("sync: server time", isinstance(d.get("time"), int) and d["time"] > 1_600_000_000_000, d.get("time"))

    for t, key in (("threads", "threads"), ("contacts", "contacts"), ("calls", "calls")):
        r = c.request(t)
        check(f"{t}: ok and list", r.get("ok") and isinstance(r.get("data", {}).get(key), list), r.get("err") or "")
    r = c.request("status")
    check("status: ok", r.get("ok") and "sims" in r.get("data", {}), r.get("err"))
    r = c.request("messages", threadId=-5)
    check("messages: invalid thread rejected (bad_request)", not r.get("ok") and r.get("err") == "bad_request", r)
    r = c.request("does_not_exist")
    check("unknown request rejected", not r.get("ok") and r.get("err") == "unknown_request", r)
    r = c.request("send_sms", to="abc", body="x")
    check("send_sms: invalid number rejected", not r.get("ok") and r.get("err") == "bad_request", r)


def run_sms(c):
    start_ms = int(time.time() * 1000) - 2000
    text = "Hello SIMBridge 42"
    emu_out = adb("emu", "sms", "send", "5551234", text).stdout
    m = c.wait_event(lambda e: e.get("t") == "sms", 25)
    ok = m is not None and text in m.get("msg", {}).get("body", "")
    check("SMS in: live event reaches iPhone", ok, m or emu_out)
    if ok:
        check("SMS in: sender address", "5551234" in m["msg"].get("address", ""), m["msg"].get("address"))
    time.sleep(3)
    r = c.request("sync", smsAfter=start_ms)
    got = [x for x in r.get("data", {}).get("sms", []) if text in x.get("body", "")]
    check("SMS in: catch-up sync after wake returns it", got, r.get("data", {}).get("sms"))
    r = c.request("threads")
    th = [t for t in r.get("data", {}).get("threads", []) if "5551234" in t.get("address", "")]
    check("SMS in: appears in conversation list", th, required=False)
    if th:
        check("SMS in: unread counted", th[0].get("unread", 0) >= 1, th[0], required=False)
        r = c.request("threads", readMarks={str(th[0]["threadId"]): int(time.time() * 1000) + 60_000})
        th2 = [t for t in r["data"]["threads"] if t["threadId"] == th[0]["threadId"]]
        check("SMS in: read mark from iPhone clears unread", th2 and th2[0]["unread"] == 0, th2)
        r = c.request("messages", threadId=th[0]["threadId"])
        msgs = r.get("data", {}).get("messages", [])
        check("messages: conversation contains the SMS", any(text in x.get("body", "") for x in msgs), len(msgs))

    # Send an SMS to the emulator's own number; it loops back as an incoming SMS.
    own = re.findall(r"\d+", adb("get-serialno").stdout) or ["5554"]
    body = "Reply from iPhone " + uuid.uuid4().hex[:6]
    r = c.request("send_sms", to=own[-1], body=body)
    check("SMS out: accepted", r.get("ok") and r.get("data", {}).get("ref"), r)
    ref = r.get("data", {}).get("ref")
    st = c.wait_event(lambda e: e.get("t") == "sms_status" and e.get("ref") == ref, 30)
    check("SMS out: delivery report 'sent'", st is not None and st.get("state") in ("sent", "delivered"), st)
    back = c.wait_event(lambda e: e.get("t") == "sms" and body in e.get("msg", {}).get("body", ""), 25)
    check("SMS out: message actually went over the radio (looped back)", back is not None, required=False)

    # Multipart goes to another number: looping a 7-part SMS back into the same emulator
    # can wedge the emulator's modem (seen on API 30), which is not something a real phone does.
    long_body = "طولانی " * 60
    r = c.request("send_sms", to="5551235", body=long_body)
    check("SMS out: long Persian (multipart) message accepted", r.get("ok"), r)
    ref = r.get("data", {}).get("ref")
    st = c.wait_event(lambda e: e.get("t") == "sms_status" and e.get("ref") == ref, 30)
    check("SMS out: multipart 'sent'", st is not None and st.get("state") in ("sent", "delivered"), st)


def run_calls(c):
    number = "5559876"
    # 1) incoming -> answer -> speaker/mute -> hang up
    adb("emu", "gsm", "call", number)
    e = c.wait_event(call_state("ringing"), 20)
    check("call in: ringing event", e is not None, e)
    if e:
        time.sleep(1.5)
        late = c.wait_event(lambda x: x.get("t") == "call" and number in x.get("call", {}).get("number", ""), 3)
        has_num = number in e["call"].get("number", "") or late is not None
        check("call in: caller number shown", has_num, e["call"], required=False)
    screenshot("05_incoming_call_android")
    r = c.request("answer", speaker=False)
    check("call in: answer accepted", r.get("ok"), r)
    e = c.wait_event(call_state("offhook"), 15)
    check("call in: now in conversation (offhook)", e is not None, e)
    # Developer-mode call audio: the app refuses cleanly without Shizuku...
    r = c.request("listen", on=True)
    check("listen: refused cleanly without Shizuku", not r.get("ok") and str(r.get("err", "")).startswith("dev_"), r)
    # ...and the exact shell pipeline it would run (scrcpy server + SocketCat) works with ADB privileges.
    check_audio_pipeline()
    r = c.request("speaker", on=True)
    check("call: speaker request ok", r.get("ok"), r)
    check("call: speaker actually on", r.get("data", {}).get("on") is True, r, required=False)
    r = c.request("speaker", on=False)
    check("call: speaker off ok", r.get("ok"), r)
    check("call: speaker actually off", r.get("data", {}).get("on") is False, r, required=False)
    r = c.request("mute", on=True)
    check("call: mute request ok", r.get("ok"), r)
    c.request("mute", on=False)
    r = c.request("hangup")
    check("call: hang up accepted", r.get("ok"), r)
    e = c.wait_event(call_state("idle"), 15)
    check("call: back to idle after hang up", e is not None, e)
    if not e:
        adb("emu", "gsm", "cancel", number)
    time.sleep(2)

    # 2) incoming -> reject
    adb("emu", "gsm", "call", number)
    e = c.wait_event(call_state("ringing"), 20)
    check("call reject: ringing", e is not None)
    r = c.request("reject")
    check("call reject: accepted", r.get("ok"), r)
    e = c.wait_event(call_state("idle"), 15)
    check("call reject: idle", e is not None, e)
    m = c.wait_event(lambda x: x.get("t") == "missed", 5)
    check("call reject: reported as rejected (no missed-call alert)", m is not None and m.get("rejected") is True, m)
    if not e:
        adb("emu", "gsm", "cancel", number)
    time.sleep(2)

    # 3) incoming -> caller hangs up -> missed call
    before = int(time.time() * 1000) - 1000
    adb("emu", "gsm", "call", number)
    e = c.wait_event(call_state("ringing"), 20)
    check("missed call: ringing", e is not None)
    time.sleep(2)
    adb("emu", "gsm", "cancel", number)
    e = c.wait_event(call_state("idle"), 15)
    check("missed call: idle", e is not None, e)
    m = c.wait_event(lambda x: x.get("t") == "missed", 5)
    check("missed call: event with rejected=false", m is not None and m.get("rejected") is False, m)
    time.sleep(3)
    r = c.request("sync", missedAfter=before)
    missed = r.get("data", {}).get("missed", [])
    check("missed call: catch-up sync lists it from call log", any(number in x.get("number", "") for x in missed), missed, required=False)
    r = c.request("calls")
    calls = r.get("data", {}).get("calls", [])
    check("call log: recent calls readable", len(calls) >= 1, calls[:3])

    # 4) outgoing call from the iPhone
    time.sleep(2)
    r = c.request("dial", number="5551212")
    check("call out: dial accepted", r.get("ok"), r)
    e = c.wait_event(call_state("offhook"), 20)
    check("call out: offhook, direction out", e is not None and e["call"].get("direction") == "out", e)
    if e:
        check("call out: dialed number shown", "5551212" in e["call"].get("number", ""), e["call"], required=False)
    r = c.request("dial", number="5551213")
    check("call out: second dial while busy is refused", not r.get("ok") and r.get("err") == "busy", r)
    time.sleep(2)
    r = c.request("hangup")
    check("call out: hang up accepted", r.get("ok"), r)
    e = c.wait_event(call_state("idle"), 15)
    check("call out: idle", e is not None, e)
    r = c.request("ussd", timeout=50, code="*140#")
    check("USSD: handled without error (reply or operator failure)",
          r.get("ok") or r.get("err") in ("ussd_failed", "timeout"), r)
    check("USSD: operator reply text", r.get("ok") and r.get("data", {}).get("text"), r, required=False)
    r = c.request("ussd", code="140")
    check("USSD: invalid code rejected", not r.get("ok") and r.get("err") == "bad_request", r)
    r = c.request("hangup")
    check("hang up with no call -> no_call", not r.get("ok") and r.get("err") == "no_call", r)


def run_security(sid):
    c = Client(os.urandom(32))
    c.connect()
    c.send_plain({"t": "hello", "mode": "dev", "id": str(uuid.uuid4()), "v": 1})
    try:
        r = c.recv(5)
    except Exception as e:
        r = {"error": str(e)}
    check("security: unknown device refused", r and r.get("code") == "unknown_device", r)
    c.close()


def run_tamper(dev_id, key):
    c = Client(key)
    c.connect()
    c.send_plain({"t": "hello", "mode": "dev", "id": dev_id, "v": 1})
    c.recv(10)
    c.ws.send_binary(os.urandom(64))  # garbage instead of a valid auth frame
    closed = False
    try:
        c.recv(5)
    except Exception:
        closed = True
    check("security: tampered/forged frame closes the connection", closed)
    c.close()


def main():
    global OUT
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk", required=True)
    ap.add_argument("--out", default="out")
    args = ap.parse_args()
    OUT = args.out
    os.makedirs(OUT, exist_ok=True)
    hang_log = open(os.path.join(OUT, "hang_traceback.txt"), "w")
    faulthandler.dump_traceback_later(25 * 60, exit=True, file=hang_log)
    api = shell("getprop ro.build.version.sdk").strip()
    print("API level", api)
    try:
        setup_device(args.apk)
        shell(f"am start -W -n {PKG}/.ui.MainActivity")
        time.sleep(4)
        if not wait_bridge(12):
            shell(f"am broadcast -a {PKG}.TEST_START -p {PKG}")
        up = wait_bridge(40)
        check("bridge service starts and listens on 8765", up)
        screenshot("01_home")
        if not up:
            raise RuntimeError("bridge not running")
        dev_id, dev_key, sid = pair()
        time.sleep(2)
        c = connect_device(dev_id, dev_key)
        shell(f"am start -n {PKG}/.ui.MainActivity")
        time.sleep(2)
        screenshot("04_home_connected")
        run_requests(c)
        run_sms(c)
        run_calls(c)
        c.close()
        run_security(sid)
        run_tamper(dev_id, dev_key)
        shell("input keyevent KEYCODE_HOME")
        time.sleep(1)
        shell("cmd uimode night yes")
        time.sleep(1)
        shell(f"am start -n {PKG}/.ui.MainActivity")
        time.sleep(3)
        screenshot("06_home_dark")
        shell("cmd uimode night no")
    except Exception as e:
        check("test run completed without exception", False, traceback.format_exc())
    crash = adb("logcat", "-d", "-b", "crash").stdout
    crashed = PKG in crash and "FATAL EXCEPTION" in crash
    check("no crash of the Android app", not crashed, crash[-1500:] if crashed else "")
    alive = shell(f"pidof {PKG}").strip()
    check("app process still alive at the end", bool(alive))

    failed = [r for r in results if r["required"] and not r["ok"]]
    warned = [r for r in results if not r["required"] and not r["ok"]]
    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump({"api": api, "results": results}, f, ensure_ascii=False, indent=1)
    with open(os.path.join(OUT, "report.md"), "w") as f:
        f.write(f"# Android E2E (API {api})\n\n{len(results) - len(failed) - len(warned)} passed, "
                f"{len(failed)} failed, {len(warned)} warnings\n\n")
        for r in results:
            mark = "PASS" if r["ok"] else ("FAIL" if r["required"] else "WARN")
            f.write(f"- {mark} {r['name']}" + (f" — `{r['detail'][:300]}`" if not r["ok"] else "") + "\n")
    with open(os.path.join(OUT, "logcat.txt"), "w") as f:
        f.write(adb("logcat", "-d", "-t", "4000").stdout)
    print(f"\n{len(failed)} failed, {len(warned)} warnings")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
