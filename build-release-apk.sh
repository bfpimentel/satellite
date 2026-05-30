#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$ROOT_DIR/app"
flutter pub get
flutter build apk --release

cd "$ROOT_DIR"
mkdir -p server/static
cp app/build/app/outputs/flutter-apk/app-release.apk server/static/satellite.apk

echo "Release APK copied to server/static/satellite.apk"
