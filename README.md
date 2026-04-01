# Satellite

White noise background player controlled by a server.

## Project Structure

```
satellite/
├── app/          # Flutter Android app
└── server/       # Python Flask server
```

## Server

### Requirements
- Python 3.8+
- Flask

### Installation
```bash
cd server
pip install flask
```

### Running
```bash
python server.py
```

The server will start on `http://localhost:5000`. Open this URL in a browser to control the playback status (Playing/Paused).

## App (Android)

### Requirements
- Flutter SDK
- Android SDK

### Installation
```bash
cd app
flutter pub get
```

### Building
```bash
cd app
flutter build apk --debug
```

### Android Permissions Required

For the app to run in the background and bypass battery optimization, you need to configure the following on the Android device:

1. **Notification Permission**
   - Should be requested automatically by the app

2. **Foreground Service Permission**
   - Enabled in `AndroidManifest.xml`

3. **Battery Optimization**
   - Go to **Settings > Apps > Satellite > Battery**
   - Select **Unrestricted** or **Allow background activity**
   - This is critical for the app to continue playing when the screen is off

4. **Auto-start (manufacturer specific)**
   - Some phones require enabling auto-start in:
   - **Settings > Apps > Battery > Auto-launch** or similar
   - Enable auto-launch for Satellite

### Configuration

The app defaults to `http://10.0.2.2:5000` (Android emulator localhost). For a physical device, change the server URL in the app to your computer's IP address (e.g., `http://192.168.1.x:5000`).

### How It Works

1. The app runs a background service that polls the server every 2 seconds
2. When server status is "Playing", white noise is generated programmatically and played
3. When server status is "Paused", playback is paused
4. If the server is unreachable, playback is paused automatically