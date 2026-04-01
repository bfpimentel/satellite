import json

from flask import Flask, jsonify, request, render_template_string
from flask_sock import Sock

app = Flask(__name__)
sock = Sock(app)

STATUS = {"state": "Paused"}
WS_CLIENTS = set()

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
        }
        h1 { margin-bottom: 40px; font-size: 24px; font-weight: 300; }
        .status {
            font-size: 48px;
            font-weight: 700;
            margin-bottom: 40px;
            text-transform: uppercase;
            letter-spacing: 4px;
        }
        .controls { display: flex; gap: 20px; }
        button {
            background: #fff;
            color: #000;
            border: none;
            padding: 20px 40px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            border-radius: 0;
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
    </style>
</head>
<body>
    <h1>Satellite Server</h1>
    <div class="status" id="status">Paused</div>
    <div class="controls">
        <button id="toggleBtn" onclick="toggleStatus()">Play</button>
    </div>
    <script>
        let ws;

        function setStatus(state) {
            return fetch('/status', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({state: state})
            }).then(r => r.json());
        }

        function render(state) {
            document.getElementById('status').textContent = state;
            const btn = document.getElementById('toggleBtn');
            const playing = state === 'Playing';
            btn.textContent = playing ? 'Pause' : 'Play';
            btn.className = playing ? '' : 'paused';
        }

        function toggleStatus() {
            const current = document.getElementById('status').textContent.trim();
            const next = current === 'Playing' ? 'Paused' : 'Playing';
            setStatus(next).then(d => render(d.state));
        }

        function connectWebSocket() {
            const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
            ws = new WebSocket(`${protocol}://${window.location.host}/ws/status`);

            ws.onmessage = (event) => {
                const data = JSON.parse(event.data);
                render(data.state || 'Unknown');
            };

            ws.onclose = () => {
                setTimeout(connectWebSocket, 1500);
            };
        }

        setInterval(() => {
            if (ws && ws.readyState === WebSocket.OPEN) {
                return;
            }
            fetch('/status').then(r => r.json()).then(d => render(d.state));
        }, 3000);

        connectWebSocket();
        render('Paused');
    </script>
</body>
</html>
"""


def broadcast_status():
    payload = json.dumps(STATUS)
    stale_clients = []

    for client in WS_CLIENTS:
        try:
            client.send(payload)
        except Exception:
            stale_clients.append(client)

    for client in stale_clients:
        WS_CLIENTS.discard(client)


@app.route("/")
def index():
    return render_template_string(HTML)


@app.route("/status", methods=["GET"])
def get_status():
    return jsonify(STATUS)


@app.route("/status", methods=["POST"])
def set_status():
    data = request.get_json()
    if data and "state" in data:
        if data["state"] in ["Playing", "Paused"]:
            STATUS["state"] = data["state"]
            broadcast_status()
    return jsonify(STATUS)


@sock.route("/ws/status")
def ws_status(ws):
    WS_CLIENTS.add(ws)
    ws.send(json.dumps(STATUS))

    try:
        while True:
            if ws.receive() is None:
                break
    finally:
        WS_CLIENTS.discard(ws)
