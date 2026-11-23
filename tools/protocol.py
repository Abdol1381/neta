"""Reference implementation of the SIMBridge wire protocol (used by the automated tests).

Frame = nonce(12) || ciphertext || tag(16), AES-256-GCM, AAD = direction label.
Must match android/.../core/Crypto.kt and ios/SIMBridge/Core/WireCrypto.swift.
"""
import base64
import hashlib
import json
import os
import urllib.parse

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

C2S = b"simbridge-c2s"
S2C = b"simbridge-s2c"


def seal(key: bytes, obj: dict, aad: bytes) -> bytes:
    nonce = os.urandom(12)
    return nonce + AESGCM(key).encrypt(nonce, json.dumps(obj, ensure_ascii=False).encode("utf-8"), aad)


def open_frame(key: bytes, frame: bytes, aad: bytes) -> dict:
    if len(frame) < 28:
        raise ValueError("short frame")
    return json.loads(AESGCM(key).decrypt(frame[:12], frame[12:], aad).decode("utf-8"))


def verification_code(pairing_key: bytes, nonce: bytes) -> str:
    h = hashlib.sha256(b"simbridge-verify" + pairing_key + nonce).digest()
    return "%04d" % (int.from_bytes(h[:4], "big") % 10000)


def ble_id(server_id: str) -> bytes:
    return hashlib.sha256(server_id.encode("utf-8")).digest()[:8]


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def unb64(s: str) -> bytes:
    return base64.b64decode(s)


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def unb64url(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def parse_pair_url(url: str) -> dict:
    u = urllib.parse.urlparse(url.strip())
    if u.scheme != "simbridge" or u.netloc != "pair":
        raise ValueError("not a simbridge pair url: " + url)
    q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query, keep_blank_values=True).items()}
    return {
        "sid": q["sid"],
        "name": q.get("n", ""),
        "port": int(q.get("p", "8765")),
        "hosts": [h for h in q.get("h", "").split(",") if h],
        "key": unb64url(q["k"]),
    }


def make_pair_url(sid: str, name: str, port: int, hosts: list, key: bytes) -> str:
    return "simbridge://pair?v=1&" + urllib.parse.urlencode(
        {"sid": sid, "n": name, "p": port, "h": ",".join(hosts), "k": b64url(key)}
    )
