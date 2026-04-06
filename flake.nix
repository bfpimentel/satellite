{
  description = "Satellite development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
        };

        android-composition = pkgs.androidenv.composeAndroidPackages {
          platformVersions = [
            "34"
            "35"
            "36"
          ];
          buildToolsVersions = [ "34.0.0" ];
          abiVersions = [
            "armeabi-v7a"
            "arm64-v8a"
            "x86"
            "x86_64"
          ];
          includeNDK = true;
          ndkVersions = [ "27.0.12077973" ];
          cmakeVersions = [ "3.22.1" ];
        };

        android-sdk = android-composition.androidsdk;

        flutter-pkgs = pkgs.flutter;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            uv
            python3
            flutter
            jdk17
            android-sdk
            nix-ld
          ];

          shellHook = ''
            export ANDROID_SDK_ROOT="${android-sdk}/libexec/android-sdk"
            export ANDROID_HOME="$ANDROID_SDK_ROOT"

            if [ -f .env ]; then
              source .env
            else
              echo "Populate .env file. See .env.example for reference."
            fi

            cd server

            if [ ! -d ".venv" ]; then
              uv venv .venv
            fi

            source .venv/bin/activate
            uv sync

            cd ../app
            if [ ! -d ".dart_tool" ]; then
              flutter pub get
            fi
            cd ..'';
        };
      }
    );
}
