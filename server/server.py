import json
import time

from flask import Flask, jsonify, render_template_string, request
from flask_sock import Sock

app = Flask(__name__)
sock = Sock(app)

STATUS = {"state": "Paused"}
WS_CLIENTS = set()
SATELLITES = {}

HTML = """
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Satellite Server</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Victor+Mono:wght@400;600;700&display=swap');
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Victor Mono', monospace;
            background: #000;
            color: #fff;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            padding: 20px;
            gap: 20px;
        }
        h1 { margin-bottom: 24px; font-size: 24px; font-weight: 300; }
        .status {
            font-size: 48px;
            font-weight: 700;
            margin-bottom: 24px;
            text-transform: uppercase;
            letter-spacing: 4px;
        }
        .controls { display: flex; gap: 20px; margin-bottom: 18px; }
        button {
            background: #fff;
            color: #000;
            border: none;
            padding: 20px 40px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            text-transform: uppercase;
            letter-spacing: 2px;
            transition: opacity 0.2s;
        }
        button:hover { opacity: 0.8; }
        button.paused {
            background: #222;
            color: #fff;
            border: 1px solid #fff;
        }
        .panel {
            width: min(720px, 92vw);
            border: 1px solid #fff;
            padding: 16px;
        }
        .panel h2 {
            font-size: 12px;
            letter-spacing: 2px;
            color: #aaa;
            margin-bottom: 10px;
        }
        .satellite-row {
            display: flex;
            justify-content: space-between;
            gap: 12px;
            padding: 8px 0;
            border-top: 1px solid #333;
            font-size: 14px;
        }
        .satellite-row:first-child { border-top: none; }
        .online { color: #8ef7a1; }
        .offline { color: #ff9b9b; }
        .dim { color: #8c8c8c; }
    </style>
</head>
<body>
    <h1>Satellite Server</h1>
    <div class="status" id="status">Paused</div>
    <div class="controls">
        <button id="toggleBtn" onclick="toggleStatus()">Play</button>
    </div>

    <div class="panel">
        <h2>SATELLITES</h2>
        <div id="satellites"></div>
    </div>

    <script>
        let ws;
        let isBusy = false;

        function setStatus(state) {
            return fetch('/status', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({state: state})
            }).then(r => r.json());
        }

        function renderSatellites(items) {
            const root = document.getElementById('satellites');
            if (!Array.isArray(items) || items.length === 0) {
                root.innerHTML = '<div class="dim">No satellites registered yet.</div>';
                return;
            }

            root.innerHTML = items.map((s) => {
                const statusClass = s.connected ? 'online' : 'offline';
                const statusText = s.connected ? 'connected' : 'disconnected';
                return `<div class="satellite-row"><span>${s.name}</span><span class="${statusClass}">${statusText}</span></div>`;
            }).join('');
        }

        function render(payload) {
            const state = payload.state || 'Unknown';
            document.getElementById('status').textContent = state;
            const btn = document.getElementById('toggleBtn');
            const playing = state === 'Playing';
            btn.textContent = playing ? 'Pause' : 'Play';
            btn.className = playing ? '' : 'paused';
            renderSatellites(payload.satellites || []);
        }

        async function toggleStatus() {
            if (isBusy) return;
            isBusy = true;
            try {
                const current = document.getElementById('status').textContent.trim();
                const next = current === 'Playing' ? 'Paused' : 'Playing';
                const data = await setStatus(next);
                render(data);
            } finally {
                isBusy = false;
            }
        }

        function connectWebSocket() {
            const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
            ws = new WebSocket(`${protocol}://${window.location.host}/ws/status`);

            ws.onmessage = (event) => {
                const data = JSON.parse(event.data);
                render(data);
            };

            ws.onclose = () => {
                setTimeout(connectWebSocket, 1500);
            };
        }

        setInterval(() => {
            if (ws && ws.readyState === WebSocket.OPEN) {
                return;
            }
            Promise.all([
                fetch('/status').then(r => r.json()),
                fetch('/satellites').then(r => r.json()),
            ]).then(([statusData, satellitesData]) => {
                render({state: statusData.state, satellites: satellitesData.satellites});
            });
        }, 3000);

        connectWebSocket();
        render({state: 'Paused', satellites: []});
    </script>
</body>
</html>
"""


def _satellite_name(item):
    return item.get("name") or "Unnamed Satellite"


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


@app.route("/")
def index():
    return render_template_string(HTML)


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


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
