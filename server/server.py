import json
import os
import time

from flask import Flask, jsonify, render_template, request
from flask_sock import Sock

app = Flask(__name__)
sock = Sock(app)

DATA_FILE = os.environ.get("SATELLITE_DATA_FILE", "satellites.json")

STATUS = {"state": "Paused"}
WS_CLIENTS = set()
SATELLITES = {}


def _satellite_name(item):
    return item.get("name") or "Unnamed Satellite"


def load_satellites():
    """Load satellites from filesystem on startup."""
    global SATELLITES
    if os.path.exists(DATA_FILE):
        try:
            with open(DATA_FILE, "r") as f:
                data = json.load(f)
                SATELLITES = data.get("satellites", {})
                print(f"Loaded {len(SATELLITES)} satellites from {DATA_FILE}")
        except Exception as e:
            print(f"Error loading satellites from {DATA_FILE}: {e}")
            SATELLITES = {}
    else:
        print(f"No existing data file at {DATA_FILE}, starting fresh")
        SATELLITES = {}


def save_satellites():
    """Persist satellites to filesystem."""
    try:
        with open(DATA_FILE, "w") as f:
            json.dump({"satellites": SATELLITES}, f, indent=2)
    except Exception as e:
        print(f"Error saving satellites to {DATA_FILE}: {e}")


def satellites_snapshot():
    now = time.time()
    items = []
    for satellite_id, item in SATELLITES.items():
        connected = item.get("connected", False)
        last_seen = item.get("last_seen", 0)
        if connected and now - last_seen > 35:
            connected = False
            item["connected"] = False
        items.append(
            {
                "id": satellite_id,
                "name": _satellite_name(item),
                "connected": connected,
                "last_seen": int(last_seen),
            }
        )

    items.sort(key=lambda x: (not x["connected"], x["name"].lower()))
    return items


def server_snapshot():
    return {"state": STATUS["state"], "satellites": satellites_snapshot()}


def broadcast_snapshot():
    payload = json.dumps(server_snapshot())
    stale_clients = []

    for client in WS_CLIENTS:
        try:
            client.send(payload)
        except Exception:
            stale_clients.append(client)

    for client in stale_clients:
        WS_CLIENTS.discard(client)


def touch_satellite(satellite_id, name=None):
    item = SATELLITES.get(
        satellite_id, {"name": "Unnamed Satellite", "connected": False, "last_seen": 0}
    )
    if name:
        item["name"] = name
    item["connected"] = True
    item["last_seen"] = time.time()
    SATELLITES[satellite_id] = item
    save_satellites()


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/status", methods=["GET"])
def get_status():
    return jsonify(server_snapshot())


@app.route("/satellites", methods=["GET"])
def get_satellites():
    return jsonify({"satellites": satellites_snapshot()})


@app.route("/status", methods=["POST"])
def set_status():
    data = request.get_json()
    if data and "state" in data and data["state"] in ["Playing", "Paused"]:
        STATUS["state"] = data["state"]
        broadcast_snapshot()
    return jsonify(server_snapshot())


@sock.route("/ws/status")
def ws_status(ws):
    WS_CLIENTS.add(ws)
    ws.send(json.dumps(server_snapshot()))
    satellite_id = None

    try:
        while True:
            message = ws.receive()
            if message is None:
                break
            try:
                data = json.loads(message)
            except Exception:
                continue

            if data.get("role") == "satellite" and data.get("id"):
                satellite_id = str(data.get("id"))
                touch_satellite(
                    satellite_id, str(data.get("name") or "Unnamed Satellite")
                )
                broadcast_snapshot()
            elif data.get("type") == "ping" and data.get("id"):
                touch_satellite(
                    str(data.get("id")), str(data.get("name") or "Unnamed Satellite")
                )
    finally:
        WS_CLIENTS.discard(ws)
        if satellite_id and satellite_id in SATELLITES:
            SATELLITES[satellite_id]["connected"] = False
            SATELLITES[satellite_id]["last_seen"] = time.time()
            broadcast_snapshot()


# Load satellites from filesystem on startup
load_satellites()
