import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SetupHelpScreen extends StatelessWidget {
  const SetupHelpScreen({this.homeAssistantUrl, super.key});

  final String? homeAssistantUrl;

  @override
  Widget build(BuildContext context) {
    final address = homeAssistantUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Hilfe beim Koppeln')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Welche Adresse wird benötigt?',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Das Feld in Home Assistant meint die Adresse deiner Home-Assistant-Installation. '
            'Die IP-Adresse dieses iPhones musst du dafür nicht heraussuchen.',
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Home-Assistant-Adresse',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (address != null) ...[
                    SelectableText(address),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: address));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Home-Assistant-Adresse kopiert'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Adresse kopieren'),
                    ),
                  ] else
                    const Text(
                      'Vor der ersten Kopplung kennt die App deine Home-Assistant-Adresse '
                      'noch nicht. Du findest sie dort, wo du Home Assistant im Browser öffnest.',
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'So findest du die richtige Adresse',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          const Text(
            '1. Öffne Home Assistant im Browser auf einem anderen Gerät.\n\n'
            '2. Nutze die Adresse aus der Adresszeile: https://, den Namen oder die IP '
            'und gegebenenfalls den Port. Entferne die Seitenadresse dahinter, '
            'zum Beispiel /config/integrations.\n\n'
            '3. Trage diese Adresse bei OpenPlate in Home Assistant ein. '
            'Wenn Home Assistant seine HTTPS-Adresse bereits kennt, erscheint der QR-Code direkt.\n\n'
            '4. Tippe auf dem iPhone auf „iPhone per QR-Code koppeln“, scanne den Code '
            'und bestätige danach in Home Assistant mit „Absenden“.',
          ),
          const SizedBox(height: 20),
          Text(
            'Beginnt deine Adresse mit http://?',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Dann ist für diese Adresse noch keine verschlüsselte Verbindung eingerichtet. '
            'HTTPS muss zuerst für Home Assistant eingerichtet sein, mit einem Zertifikat, '
            'dem das iPhone vertraut. Nur http:// durch https:// zu ersetzen reicht nicht. '
            'Die Einrichtung kann Unterstützung durch die Person erfordern, die Home Assistant betreut.',
          ),
          const SizedBox(height: 20),
          const Text(
            'Der Erkennungsserver wird anschließend separat in Home Assistant eingerichtet. '
            'Seine Adresse brauchst du zum Koppeln des iPhones noch nicht.',
          ),
        ],
      ),
    );
  }
}
