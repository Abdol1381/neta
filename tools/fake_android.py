#!/usr/bin/env python3
"""Fake Android agent for the iOS Simulator UI test.

Speaks the real SIMBridge protocol (see protocol.py) with Persian sample data, auto-approves
pairing after a delay (so the confirm-code screen can be captured) and logs every request it
receives to --log so the test can assert the iPhone app really used the API.
If the file --call-flag exists, a ringing call is pushed 2 s after each device connects.
"""
import argparse
import asyncio
import json
import os
import time
import uuid

import websockets

import protocol as P

ARGS = None
SID = "f4ke5e4v-0000-4000-8000-" + uuid.uuid4().hex[:12]
PAIR_KEY = os.urandom(32)
DEVICES = {}
LOG = []


def now_ms():
    return int(time.time() * 1000)


def log(kind, detail=""):
    LOG.append({"t": round(time.time(), 2), "kind": kind, "detail": detail})
    with open(ARGS.log, "w") as f:
        json.dump(LOG, f, ensure_ascii=False, indent=1)
    print(kind, detail, flush=True)


MIN = 60_000
HOUR = 60 * MIN
DAY = 24 * HOUR


def status():
    return {
        "sims": [
            {"subId": 1, "slot": 0, "carrier": "همراه اول", "name": "SIM 1", "number": "", "level": 4, "dbm": -81,
             "net": "LTE", "gen": "4G", "service": "in", "roaming": False, "smsSim": True, "voiceSim": True, "dataSim": True},
            {"subId": 2, "slot": 1, "carrier": "ایرانسل", "name": "SIM 2", "number": "", "level": 2, "dbm": -103,
             "net": "HSPA+", "gen": "3G", "service": "in", "roaming": False, "smsSim": False, "voiceSim": False, "dataSim": False},
        ],
        "battery": {"level": 76, "charging": False},
        "airplane": False,
        "device": {"model": "Mi A3", "android": "11"},
        "perms": {"sms": True, "phone": True, "callLog": True, "contacts": True},
    }


def threads():
    n = now_ms()
    return [
        {"threadId": 1, "address": "09121234567", "name": "مریم احمدی", "snippet": "باشه، پس فردا ساعت ۱۰ می‌بینمت",
         "date": n - 4 * MIN, "out": False, "unread": 2},
        {"threadId": 2, "address": "9990", "name": "همراه اول", "snippet": "بسته اینترنت ۳۰ روزه شما با موفقیت فعال شد.",
         "date": n - 2 * HOUR, "out": False, "unread": 0},
        {"threadId": 3, "address": "09351112233", "name": "علی رضایی", "snippet": "مرسی، رسید 🙏",
         "date": n - DAY - 3 * HOUR, "out": True, "unread": 0},
        {"threadId": 4, "address": "+989198887766", "name": "", "snippet": "کد تأیید شما: 48213",
         "date": n - 3 * DAY, "out": False, "unread": 0},
        {"threadId": 5, "address": "BankMellat", "name": "", "snippet": "برداشت: ۲,۵۰۰,۰۰۰ ریال — مانده: ۱۸,۷۴۰,۰۰۰",
         "date": n - 9 * DAY, "out": False, "unread": 0},
    ]


def messages(tid):
    n = now_ms()
    if tid != 1:
        t = next((x for x in threads() if x["threadId"] == tid), None)
        if not t:
            return []
        return [{"id": f"{tid}-1", "threadId": tid, "address": t["address"], "name": t["name"], "body": t["snippet"],
                 "date": t["date"], "out": t["out"], "status": "ok", "read": True, "subId": 1}]
    conv = [
        (False, "سلام! خوبی؟", DAY + 2 * HOUR),
        (True, "سلام مریم، ممنون. تو خوبی؟", DAY + 2 * HOUR - 3 * MIN),
        (False, "فردا جلسه با مشتری ساعت چنده؟", 30 * MIN),
        (True, "ساعت ۱۰ صبح، دفتر خودمون", 25 * MIN),
        (False, "عالیه 👌 فایل ارائه رو هم میاری؟", 6 * MIN),
        (False, "باشه، پس فردا ساعت ۱۰ می‌بینمت", 4 * MIN),
    ]
    return [{"id": f"1-{i}", "threadId": 1, "address": "09121234567", "name": "مریم احمدی", "body": b,
             "date": n - ago, "out": out, "status": "ok", "read": True, "subId": 1}
            for i, (out, b, ago) in enumerate(conv)]


def contacts():
    names = [("آرش کریمی", ["09121110000"]), ("الهام نوری", ["09132223344"]), ("بابا", ["09120001122", "02188776655"]),
             ("حسین مرادی", ["09356667788"]), ("زهرا محمدی", ["09194445566"]), ("علی رضایی", ["09351112233"]),
             ("مامان", ["09123334455"]), ("مریم احمدی", ["09121234567"]), ("Sara Miller", ["+447700900123"])]
    return [{"id": i + 1, "name": n, "numbers": nums} for i, (n, nums) in enumerate(names)]


def calls():
    n = now_ms()
    rows = [("09121234567", "مریم احمدی", 20 * MIN, 184, "in"), ("09123334455", "مامان", 3 * HOUR, 0, "missed"),
            ("09351112233", "علی رضایی", DAY, 62, "out"), ("+989198887766", "", DAY + 5 * HOUR, 0, "rejected"),
            ("02188776655", "بابا", 2 * DAY, 431, "in"), ("09121110000", "آرش کریمی", 4 * DAY, 15, "out")]
    return [{"id": i + 1, "number": num, "name": nm, "date": n - ago, "duration": d, "type": t}
            for i, (num, nm, ago, d, t) in enumerate(rows)]


CALL = {"state": "idle", "number": "", "name": "", "direction": "", "since": 0, "subId": -1}


async def handler(ws):
    send_lock = asyncio.Lock()
    key = None

    async def send(obj):
        async with send_lock:
            await ws.send(P.seal(key, obj, P.S2C))

    log("connection", str(ws.remote_address))
    try:
        hello = json.loads(await ws.recv())
        log("hello", hello)
        if hello.get("mode") == "pair":
            key, pairing = PAIR_KEY, True
        elif hello.get("mode") == "dev" and hello.get("id") in DEVICES:
            key, pairing, dev_id = DEVICES[hello["id"]], False, hello["id"]
        else:
            log("refused", hello)
            await ws.send(json.dumps({"t": "error", "code": "unknown_device"}))
            await asyncio.sleep(0.3)
            return
        nonce = os.urandom(16)
        await send({"t": "challenge", "n": P.b64(nonce), "sid": SID, "v": 1})
        auth = P.open_frame(key, await ws.recv(), P.C2S)
        if auth.get("t") != "auth" or auth.get("n") != P.b64(nonce):
            log("bad_auth", auth)
            return
        if pairing:
            log("pair_request", {"name": auth.get("name"), "code": P.verification_code(key, nonce)})
            await asyncio.sleep(ARGS.approve_delay)
            dev_id = str(uuid.uuid4())
            DEVICES[dev_id] = os.urandom(32)
            await send({"t": "paired", "id": dev_id, "key": P.b64(DEVICES[dev_id]), "sid": SID, "name": "Xiaomi Mi A3"})
            log("paired", dev_id)
            await asyncio.sleep(1.5)
            return
        log("ready", auth.get("name"))
        await send({"t": "ready", "sid": SID, "name": "Xiaomi Mi A3", "hosts": ["127.0.0.1"], "port": ARGS.port})

        async def ring_later():
            await asyncio.sleep(2)
            CALL.update(state="ringing", number="09121234567", name="مریم احمدی", direction="in", since=now_ms(), subId=2)
            await send({"t": "call", "call": dict(CALL)})

        if os.path.exists(ARGS.call_flag):
            asyncio.create_task(ring_later())
        else:
            CALL.update(state="idle", number="", name="", direction="", since=0)

        async for frame in ws:
            req = P.open_frame(key, frame, P.C2S)
            t, rid = req.get("t"), req.get("rid")
            if t == "ping":
                await send({"t": "pong", "rid": rid, "ts": req.get("ts")})
                continue
            log("request", t)
            data, err = {}, None
            if t == "sync":
                data = {"status": status(), "call": dict(CALL), "audio": {"speaker": False, "muted": False}, "time": now_ms()}
                if req.get("smsAfter"):
                    data["sms"] = []
                if req.get("missedAfter"):
                    data["missed"] = []
            elif t == "status":
                data = status()
            elif t == "threads":
                data = {"threads": threads()}
            elif t == "messages":
                data = {"messages": messages(int(req.get("threadId", -1)))}
            elif t == "contacts":
                data = {"contacts": contacts()}
            elif t == "calls":
                data = {"calls": calls()}
            elif t == "send_sms":
                ref = str(uuid.uuid4())
                data = {"ref": ref}

                async def report(ref=ref):
                    await asyncio.sleep(0.6)
                    await send({"t": "sms_status", "ref": ref, "state": "sent"})
                    await asyncio.sleep(0.8)
                    await send({"t": "sms_status", "ref": ref, "state": "delivered"})
                asyncio.create_task(report())
            elif t == "dial":
                CALL.update(state="offhook", number=req.get("number", ""), name="", direction="out", since=now_ms())
                asyncio.create_task(send({"t": "call", "call": dict(CALL)}))
            elif t in ("answer",):
                CALL.update(state="offhook", since=now_ms())
                asyncio.create_task(send({"t": "call", "call": dict(CALL)}))
            elif t in ("reject", "hangup"):
                CALL.update(state="idle", number="", name="", direction="", since=0)
                asyncio.create_task(send({"t": "call", "call": dict(CALL)}))
            elif t == "ussd":
                await asyncio.sleep(1)
                data = {"text": "مانده حساب شما: ۱۲۵,۴۰۰ ریال" + chr(10) + "اعتبار تا ۱۴۰۵/۰۹/۳۰"}
            elif t in ("speaker", "mute"):
                data = {"on": bool(req.get("on"))}
            else:
                err = "unknown_request"
            await send({"t": "res", "rid": rid, "ok": err is None, **({"data": data} if err is None else {"err": err})})
    except websockets.ConnectionClosed:
        pass
    except Exception as e:  # keep the server alive for the next launch
        log("error", repr(e))


async def log_request(path, headers):
    log("http_request", {"path": path, "headers": dict(headers.raw_items())})
    return None


async def main():
    with open(ARGS.payload_out, "w") as f:
        f.write(P.make_pair_url(SID, "Xiaomi Mi A3", ARGS.port, ["127.0.0.1"], PAIR_KEY))
    log("listening", ARGS.port)
    async with websockets.serve(handler, "0.0.0.0", ARGS.port, max_size=16 * 1024 * 1024, process_request=log_request):
        await asyncio.Future()


if __name__ == "__main__":
    import logging
    logging.basicConfig(level=logging.DEBUG, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--payload-out", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--call-flag", default="/tmp/simbridge_call")
    ap.add_argument("--approve-delay", type=float, default=6)
    ARGS = ap.parse_args()
    asyncio.run(main())
