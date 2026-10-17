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
            'Die IP-Adresse dieses iPhones musst du dafür nicht heraussuchen. '
            'OpenPlate ermittelt die lokale Home-Assistant-Adresse normalerweise automatisch.',
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
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Vor der ersten Kopplung ist deine Adresse hier noch nicht bestätigt. '
                          'Die übliche lokale Adresse lautet:',
                        ),
                        SizedBox(height: 8),
                        SelectableText('http://homeassistant.local:8123'),
                        SizedBox(height: 8),
                        Text(
                          'Dieser Vorschlag ist nicht überprüft. Bei einem anderen Namen '
                          'oder Netzwerk kann die Adresse abweichen.',
                        ),
                      ],
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
            '2. Nutze die Adresse aus der Adresszeile: http:// oder https://, den Namen oder die IP '
            'und gegebenenfalls den Port. Entferne die Seitenadresse dahinter, '
            'zum Beispiel /config/integrations.\n\n'
            '3. Trage diese Adresse bei OpenPlate in Home Assistant ein. '
            'Normalerweise wird sie automatisch ermittelt und der QR-Code erscheint direkt.\n\n'
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
            'Das ist im Heimnetz in Ordnung. OpenPlate verschlüsselt die Kopplung, '
            'Einstellungen und Kennzeichenmeldungen selbst. Der QR-Code stellt die sichere '
            'Verbindung her; für Home Assistant musst du dafür keine Zertifikate einrichten. '
            'Teile den QR-Code nicht mit anderen.',
          ),
          const SizedBox(height: 20),
          const Text(
            'Detection, OCR und Mehrfachbestätigung laufen lokal auf dem iPhone. '
            'Du brauchst keinen Erkennungsserver. Die Modelle werden beim ersten Start '
            'heruntergeladen und danach offline genutzt. Kamerabilder bleiben auf dem Handy; '
            'nur bestätigte Kennzeichen werden verschlüsselt an Home Assistant gesendet.',
          ),
        ],
      ),
    );
  }
}
