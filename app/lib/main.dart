import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'stores/audio_store.dart';
import 'stores/satellite_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final audioStore = AudioStore();
  final satelliteStore = SatelliteStore();

  await satelliteStore.init();
  audioStore.init();

  audioStore.setSatelliteIdentity(
    id: satelliteStore.state.value.satelliteId,
    name: satelliteStore.state.value.satelliteName,
  );

  if (satelliteStore.state.value.isConfigured) {
    await audioStore.setServerUrl(satelliteStore.state.value.serverUrl);
  }

  runApp(const SatelliteApp());
}

class SatelliteApp extends StatelessWidget {
  const SatelliteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Satellite',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Victor Mono',
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final satelliteStore = SatelliteStore();

    return Watch((context) {
      final state = satelliteStore.state.value;
      if (!state.isConfigured) {
        return const SetupScreen();
      }
      return const MainScreen();
    });
  }
}

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final satelliteStore = SatelliteStore();
    final audioStore = AudioStore();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SATELLITE',
          style: TextStyle(fontWeight: FontWeight.w300, letterSpacing: 4),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            const Text(
              'SETUP',
              style:
                  TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            const Text(
              'Enter the server URL to connect to',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: satelliteStore.urlController,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                labelText: 'Server URL',
                labelStyle: TextStyle(color: Colors.grey),
                hintText: 'http://192.168.1.100:5000',
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: satelliteStore.nameController,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                labelText: 'Satellite Name',
                labelStyle: TextStyle(color: Colors.grey),
                hintText: 'Bedroom Speaker',
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            const Spacer(),
            const SizedBox(height: 16),
            SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: () async {
                  final url = satelliteStore.urlController.text.trim();
                  final name = satelliteStore.nameController.text.trim().isEmpty
                      ? 'Unnamed Satellite'
                      : satelliteStore.nameController.text.trim();

                  await satelliteStore.saveConfiguration(url, name);
                  audioStore.setSatelliteIdentity(
                    id: satelliteStore.state.value.satelliteId,
                    name: name,
                  );
                  await audioStore.setServerUrl(url);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                child: const Text(
                  'SAVE',
                  style:
                      TextStyle(letterSpacing: 2, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final satelliteStore = SatelliteStore();
    final audioStore = AudioStore();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SATELLITE',
          style: TextStyle(fontWeight: FontWeight.w300, letterSpacing: 4),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Watch((context) {
          final satelliteState = satelliteStore.state.value;
          final audioState = audioStore.state.value;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              const Text(
                'SERVER STATUS',
                style: TextStyle(
                    fontSize: 12, letterSpacing: 2, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Text(
                audioState.serverStatus.toUpperCase(),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 48),
              const Text(
                'PLAYBACK',
                style: TextStyle(
                    fontSize: 12, letterSpacing: 2, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Text(
                audioState.isPlaying ? 'PLAYING' : 'PAUSED',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                  color: audioState.isPlaying ? Colors.white : Colors.grey,
                ),
              ),
              const Spacer(),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: () => audioStore.toggleServerStatus(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                  ),
                  child: Text(
                    audioState.serverStatus == 'Playing'
                        ? 'REQUEST PAUSE'
                        : 'REQUEST PLAY',
                    style: const TextStyle(
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (!satelliteState.hasPermissions) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration:
                      BoxDecoration(border: Border.all(color: Colors.white)),
                  child: const Column(
                    children: [
                      Text(
                        'BACKGROUND PERMISSIONS REQUIRED',
                        style: TextStyle(fontSize: 12, letterSpacing: 2),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Go to Android Settings > Apps > Satellite > Battery > Allow background activity',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => satelliteStore.requestPermissions(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                    padding: const EdgeInsets.symmetric(vertical: 20),
                  ),
                  child: const Text(
                    'REQUEST PERMISSIONS',
                    style: TextStyle(letterSpacing: 2),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                'SATELLITE: ${satelliteState.satelliteName.toUpperCase()}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  letterSpacing: 2,
                  color: Colors.white,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () async {
                  await satelliteStore.clearConfiguration();
                  await audioStore.setServerUrl('');
                },
                child: const Text(
                  'CHANGE SERVER URL',
                  style: TextStyle(letterSpacing: 2, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 40),
            ],
          );
        }),
      ),
    );
  }
}
