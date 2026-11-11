#!/usr/bin/env python3
"""radio-scheduler — turns an FSAPI (Frontier Silicon / UNDOK) radio on at planned times and plays a preset.

Runs on an always-on machine in the same LAN as the radio, so the Mac doesn't need to be awake.
The macOS app pushes the plan list here; this service fires each plan once at its start time:
power on -> Internet radio mode -> preset (looked up by station name) -> volume.
The station keeps playing afterwards.

Standard library only. HTTP API (LAN), all but /health require header `X-Token`:
  GET  /health            -> {"ok": true}
  GET  /schedule          -> {"plans": [...]}
  PUT  /schedule          <- {"plans": [{"id", "station", "slot", "title", "start"}]}   (replaces the list)
  GET  /status            -> {"plans": [...], "history": [...last events...], "now": ...}
`start` is ISO 8601 with offset, e.g. "2026-11-11T21:00:00+01:00".
"""
import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path(__file__).resolve().parent
RADIO_HOST = os.environ.get("RADIO_HOST", "")
if not RADIO_HOST:
    raise SystemExit("Set RADIO_HOST (the radio's IP address), e.g. in the systemd unit.")
RADIO_PIN = os.environ.get("RADIO_PIN", "1234")
PORT = int(os.environ.get("PORT", "8735"))
VOLUME = int(os.environ.get("VOLUME", "14"))
TOKEN = (HOME / "token").read_text().strip()
PLANS_FILE = HOME / "plans.json"
HISTORY_FILE = HOME / "history.json"
FIRE_WINDOW = timedelta(minutes=10)     # still fire if we were down for a few minutes
KEEP_FIRED = timedelta(days=1)

lock = threading.Lock()


def log(msg):
    print(f"{datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def load(path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    tmp.replace(path)


def add_history(event):
    with lock:
        history = load(HISTORY_FILE, [])
        history.append(event)
        save(HISTORY_FILE, history[-100:])


# --- FSAPI -----------------------------------------------------------------------------------

class Radio:
    def __init__(self):
        self.sid = None

    def _req(self, path, **params):
        params["pin"] = RADIO_PIN
        if self.sid:
            params["sid"] = self.sid
        url = f"http://{RADIO_HOST}/fsapi/{path}?" + urllib.parse.urlencode(params)
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.read().decode("utf-8", "replace")

    def session(self):
        self.sid = None
        xml = self._req("CREATE_SESSION")
        m = re.search(r"<sessionId>(.*?)</sessionId>", xml)
        if not m:
            raise RuntimeError("no FSAPI session")
        self.sid = m.group(1)

    def set(self, node, value):
        ok = "FS_OK" in self._req(f"SET/{node}", value=value)
        if not ok:
            raise RuntimeError(f"SET {node}={value} failed")

    def get(self, node):
        m = re.search(r"<value><\w+>(.*?)</\w+></value>", self._req(f"GET/{node}"), re.S)
        return m.group(1) if m else None

    def presets(self):
        self.set("netRemote.nav.state", 1)
        for _ in range(6):
            xml = self._req("LIST_GET_NEXT/netRemote.nav.presets/-1", maxItems=60)
            if "FS_OK" in xml:
                out = []
                for key, body in re.findall(r'<item key="(\d+)">(.*?)</item>', xml, re.S):
                    m = re.search(r'<field name="name"><c8_array>(.*?)</c8_array>', body, re.S)
                    name = (m.group(1) if m else "").replace("&amp;", "&")
                    out.append((int(key), name))
                return out
            time.sleep(0.5)
        raise RuntimeError("cannot read presets")


def norm(s):
    return " ".join(s.lower().split())


def find_slot(presets, station, hint):
    wanted = norm(station)
    for slot, name in presets:
        if name and norm(name) == wanted:
            return slot
    for slot, name in presets:
        if name and (wanted in norm(name) or norm(name) in wanted):
            return slot
    return hint


def fire(plan):
    """Power on, Internet radio, preset by name, volume. Retries the whole sequence."""
    last_error = None
    for attempt in range(1, 4):
        radio = Radio()
        try:
            radio.session()
            if radio.get("netRemote.sys.power") != "1":
                radio.set("netRemote.sys.power", 1)
                time.sleep(4)
            if radio.get("netRemote.sys.mode") != "0":
                radio.set("netRemote.sys.mode", 0)
                time.sleep(2)
            slot = find_slot(radio.presets(), plan["station"], plan.get("slot"))
            if slot is None:
                raise RuntimeError(f"no preset for {plan['station']!r}")
            radio.set("netRemote.nav.state", 1)
            radio.set("netRemote.nav.action.selectPreset", slot)
            time.sleep(1)
            radio.set("netRemote.sys.audio.volume", VOLUME)
            time.sleep(6)
            playing = radio.get("netRemote.play.info.name") or ""
            return {"ok": True, "slot": slot, "playing": playing, "attempt": attempt}
        except Exception as e:  # noqa: BLE001 - report any failure, then retry
            last_error = str(e)
            log(f"fire attempt {attempt} failed: {e}")
            time.sleep(5 * attempt)
    return {"ok": False, "error": last_error}


def scheduler_loop():
    while True:
        try:
            now = datetime.now(timezone.utc)
            with lock:
                plans = load(PLANS_FILE, [])
            due = [p for p in plans
                   if not p.get("fired")
                   and datetime.fromisoformat(p["start"]) <= now < datetime.fromisoformat(p["start"]) + FIRE_WINDOW]
            for plan in due:
                log(f"firing {plan['station']} — {plan.get('title')}")
                result = fire(plan)
                event = {"at": datetime.now().astimezone().isoformat(timespec="seconds"),
                         "id": plan["id"], "station": plan["station"], "title": plan.get("title"), **result}
                add_history(event)
                log(f"result {event}")
                with lock:
                    current = load(PLANS_FILE, [])
                    for p in current:
                        if p["id"] == plan["id"]:
                            p["fired"] = event["at"]
                            p["ok"] = result["ok"]
                    save(PLANS_FILE, current)
            # Housekeeping: forget plans that ended long ago.
            with lock:
                current = load(PLANS_FILE, [])
                kept = [p for p in current if datetime.fromisoformat(p["start"]) > now - KEEP_FIRED]
                if len(kept) != len(current):
                    save(PLANS_FILE, kept)
        except Exception as e:  # noqa: BLE001 - never let the loop die
            log(f"loop error: {e}")
        time.sleep(15)


# --- HTTP API --------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if self.headers.get("X-Token") == TOKEN:
            return True
        self._send(401, {"error": "unauthorized"})
        return False

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True})
        if not self._authorized():
            return
        with lock:
            plans = load(PLANS_FILE, [])
            history = load(HISTORY_FILE, [])
        if self.path == "/schedule":
            return self._send(200, {"plans": plans})
        if self.path == "/status":
            return self._send(200, {"plans": plans, "history": history[-20:],
                                    "now": datetime.now().astimezone().isoformat(timespec="seconds")})
        self._send(404, {"error": "not found"})

    def do_PUT(self):
        if not self._authorized():
            return
        if self.path != "/schedule":
            return self._send(404, {"error": "not found"})
        try:
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            incoming = data["plans"]
            for p in incoming:
                datetime.fromisoformat(p["start"])      # validate
                assert p.get("id") and p.get("station")
        except Exception as e:  # noqa: BLE001
            return self._send(400, {"error": f"bad payload: {e}"})
        with lock:
            # Keep fired/ok markers for plans that are still in the list.
            old = {p["id"]: p for p in load(PLANS_FILE, [])}
            merged = []
            for p in incoming:
                prev = old.get(p["id"], {})
                merged.append({**p, **{k: prev[k] for k in ("fired", "ok") if k in prev}})
            save(PLANS_FILE, merged)
        log(f"schedule updated: {len(merged)} plans")
        self._send(200, {"plans": merged})

    def log_message(self, fmt, *args):  # quieter access log
        pass


if __name__ == "__main__":
    threading.Thread(target=scheduler_loop, daemon=True).start()
    log(f"radio-scheduler on :{PORT}, radio {RADIO_HOST}, volume {VOLUME}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
