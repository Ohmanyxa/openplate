import 'package:flutter/material.dart';

import 'settings.dart';
import 'vehicle_verification.dart';

class VehicleProfilesScreen extends StatefulWidget {
  const VehicleProfilesScreen({
    required this.settings,
    this.verifierFactory,
    super.key,
  });
  final OpenPlateSettings settings;
  final VehicleVerifier Function(OpenPlateSettings)? verifierFactory;
  @override
  State<VehicleProfilesScreen> createState() => _VehicleProfilesScreenState();
}

class _VehicleProfilesScreenState extends State<VehicleProfilesScreen> {
  late final verifier =
      widget.verifierFactory?.call(widget.settings) ??
      VehicleVerifier(widget.settings);
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await verifier.load(widget.settings.registeredPlates.keys);
    } on Object {
      error = 'Lokale Profile konnten nicht gelesen werden.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _change(Future<void> Function() action) async {
    try {
      await action();
      error = null;
    } on Object catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Fahrzeugprofile')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Einlernen in der Live-Kamera: Kamera starten und das angezeigte Fahrzeug bestätigen. Die Erkennung läuft automatisch. '
                'Referenzen bleiben lokal. Erst nach mehreren Begegnungen den automatischen Vergleich bewusst aktivieren.',
              ),
              const SizedBox(height: 16),
              if (!widget.settings.supportsVehicleVerification)
                const Text(
                  'Home-Assistant-Integration aktualisieren: Fahrzeugprüfung noch nicht unterstützt.',
                ),
              if (widget.settings.registeredPlates.isEmpty)
                const Text(
                  'Keine Kennzeichen übertragen. In Home Assistant anlegen und Verbindung aktualisieren.',
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              for (final plate in widget.settings.registeredPlates.keys)
                _card(plate),
            ],
          ),
  );
  Widget _card(String plate) {
    final profile = verifier.profiles[plate];
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(plate, style: Theme.of(context).textTheme.titleLarge),
              Text(widget.settings.registeredPlates[plate]!),
              const SizedBox(height: 8),
              Text(
                profile == null
                    ? 'Noch nicht eingelernt'
                    : '${profile.type} · ${profile.color}\n${profile.references.length}/6 Referenzen · '
                          '${profile.encounters}/3 Aufnahmegruppen · Front und Heck erforderlich\n'
                          '${profile.automatic ? "Automatischer Vergleich" : "Geführter Modus"}',
              ),
              if (profile != null && !profile.automatic)
                FilledButton.tonal(
                  onPressed: profile.ready
                      ? () async {
                          final approved = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Vergleich aktivieren?'),
                              content: const Text(
                                'Die manuelle Bestätigung entfällt. Der Ähnlichkeitsschwellwert ist '
                                'noch nicht für deine Montage kalibriert. Das ist keine sichere Fahrzeugauthentifizierung. '
                                'Die Referenzen werden nicht automatisch weitergelernt.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Abbrechen'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Aktivieren'),
                                ),
                              ],
                            ),
                          );
                          if (approved == true) {
                            await _change(
                              () => verifier.enableComparison(plate),
                            );
                          }
                        }
                      : null,
                  child: const Text('Automatischen Vergleich aktivieren'),
                ),
              if (profile != null)
                TextButton(
                  onPressed: () async {
                    final approved = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Profil zurücksetzen?'),
                        content: const Text(
                          'Alle lokalen Referenzen dieses Kennzeichens werden gelöscht. Danach ist wieder Einlernen nötig.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Abbrechen'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Zurücksetzen'),
                          ),
                        ],
                      ),
                    );
                    if (approved == true) {
                      await _change(() => verifier.reset(plate));
                    }
                  },
                  child: const Text('Zurücksetzen / erneut einlernen'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
