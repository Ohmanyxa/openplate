# Sicherheitsprüfung OpenPlate — 19. Oktober 2026

Umfang: lokale Quellcodeprüfung von v0.7.0 und dem aktuellen Arbeitsstand, Kryptografie-/Replay-Tests,
lokale Reproduktion der Altersprüfung und Python-Abhängigkeitsprüfung. Keine unabhängige Prüfung,
kein Penetrationstest deiner laufenden HA-Instanz, kein Audit von iOS/HA als Gesamtplattform.
Die neuen Torzuordnungen und Richtungswerte führen **keine Toraktionen** aus.

## Ergebnisse, nach Risiko für eine spätere Torautomation

### Hoch: Kennzeichen und Bildbewegung sind kein Zutrittsnachweis

Ein Foto/Bildschirm oder ein nachgemachtes Kennzeichen kann vor einer Kamera erkannt werden.
Vergrößern eines Bildes kann auch eine Annäherung vortäuschen. Ein kompromittiertes gekoppeltes
iPhone oder ein entwendeter Geräteschlüssel kann beliebige plausible Kennzeichen-/Richtungswerte
senden. Die Verschlüsselung prüft Schlüsselbesitz, nicht den Ursprung einer Aufnahme.

Dies ist eine Architekturgrenze, kein nachgewiesener Bruch von AES-GCM. Torfreigabe nur mit weiteren
unabhängigen Bedingungen, etwa Anwesenheit eines autorisierten Gerätes, geeigneten Tor-/Belegungssensoren,
Sperrzeiten und der Sicherheitstechnik des Torantriebs. `unknown` darf keine Fahrtrichtung auslösen.

### Hoch unter aktivem LAN-Angreifer: QR-Vertrauen bei ungeschützter HA-Weboberfläche

Die App-Nachrichten sind auch auf lokalem HTTP authentifiziert verschlüsselt. Wird aber die HA-Seite,
auf der der QR angezeigt wird, über ungeschütztes HTTP manipuliert oder ausgelesen, kann ein aktiver
Netzangreifer den Bootstrap-Schlüssel abgreifen oder den QR ersetzen. Anwendungskryptografie schützt
die Herkunft dieser Seite nicht. Der QR ist bis zum Verbrauch ein Kopplungsgeheimnis.

Für sicherheitsrelevanten Einsatz QR über eine vertrauenswürdige HTTPS-HA-Oberfläche anzeigen und
das Heimnetz absichern. Alternativ ist ein separat verifizierter Fingerabdruck/Out-of-band-Abgleich
nötig; dieser ist derzeit nicht implementiert. Niemals eine Zertifikatswarnung ignorieren.

### Mittel: Alter der Beobachtung wird serverseitig nicht erzwungen — reproduziert, offen

`OpenPlateManager._validate_payload()` parst `payload.timestamp`, prüft aber nicht dessen Alter oder
Zeitzone. Das 90-Sekunden-Fenster in `encryption.unseal()` gilt nur für die äußere Nachrichtenhülle.
Die iPhone-Warteschlange verwirft alte Ereignisse nach zehn Sekunden; das ist keine Servergarantie.

Lokale Probe mit einem frischen gültigen v2-Umschlag, gültiger Session und einer Beobachtung vom
`2000-01-01T00:00:00+00:00`: **HTTP 200, registriertes Kennzeichen wurde als anwesend markiert**.
Das Erzeugen einer neuen gültigen Hülle benötigt den Geräteschlüssel. Unveränderte Pakete lassen
sich ohne Schlüssel nur innerhalb des äußeren Fensters verzögert erstmalig zustellen; bereits
verarbeitete v2-Nachrichten werden abgewiesen. Ein gültiger Schlüssel allein beweist nie Echtzeit.

Empfehlung vor einer automatischen Torfreigabe: serverseitig eine kurze Beobachtungs-TTL samt
zulässiger Uhrabweichung erzwingen; doppelte und unplausible Zustandswechsel ablehnen.
Diese Prüfung wurde hier diagnostiziert, nicht stillschweigend als behoben markiert.

### Mittel: Überlastungsschutz ist unvollständig — Codebefund, nicht lastgetestet

Beide HA-Webhooks begrenzen die Nutzlast auf 16 KiB, lesen bei unbekannter Content-Length aber
zunächst `request.read()`. Das prüft nicht frühzeitig auf Streaming-/Chunk-Grenzen. Vorgelagerte
HA/aiohttp-Grenzen können größeren Schaden begrenzen; ihre tatsächliche Konfiguration wurde nicht
geprüft. Eine eigene Rate-Limitierung für Entschlüsselungsversuche fehlt. Replay-Caches sind
zeitlich, aber nicht nach Anzahl begrenzt. Ein Client mit gültigem Schlüssel kann sie aufblähen.

Auch die App liest HTTP-Antworten vor dem Entschlüsseln vollständig in den Speicher (mit Timeout,
ohne eigene Byte-Obergrenze). Das ist ein Verfügbarkeitsrisiko, keine nachgewiesene Möglichkeit,
ohne Schlüssel ein Torereignis zu erzeugen. Empfehlung: begrenzte Streaming-Reads, klare Größenlimits,
Rate-/Parallelitätslimits und feste Cache-Obergrenzen.

### Mittel, nur Altbestand: alter HTTPS/HMAC-Kompatibilitätspfad

Einträge mit `transport_version=1` behalten auf HTTPS den alten HMAC-Pfad. Dieser verwendet keine
HA-Session und keine v2-Ereignis-ID-Deduplizierung; der Nonce-Speicher wird bei Neustart verworfen.
Für v2-Einträge wird Klartext abgewiesen. Bei alten Installationen neu per QR koppeln, um auf v2 zu
wechseln. Langfristig den Legacy-Pfad entfernen. Die Version deiner produktiven Konfiguration wurde
nicht ausgelesen.

### Identitätskollisionen bei Umlauten — Vergleich im Arbeitsstand korrigiert

v0.7.0 entfernte `Ä/Ö/Ü` aus registrierten Kennzeichen: `MÜAB12` konnte auf `MAB12` fallen. Der neue
Vergleich erhält Umlaute (und normalisiert zusammengesetztes/dekomponiertes Unicode). `MÜ`, `MU`
und `M` werden nicht automatisch gleichgesetzt. ASCII-Kennzeichen behalten ihre IDs; bestehende
Umlaut-Sensoren können wegen des korrigierten Schlüssels neue Entity-IDs bekommen. Alte Entity-Registry-
Einträge/Automationen nach dem Upgrade kontrollieren.

Das OCR-Modell selbst hat weiterhin nur das Alphabet `0–9`, `A–Z` plus Padding. Diese Korrektur
erkennt keine Umlautpunkte. Dafür ist ein anderes/nachtrainiertes Modell oder ein gesondert
validierter zusätzlicher lokaler OCR-Pfad nötig. Keine unsicheren automatischen A/Ä-, O/Ö-, U/Ü-Aliase
für Torberechtigungen verwenden.

### Datenschutz/Betrieb

Kennzeichen, Richtung, Torzuordnung und Anwesenheit stehen als Klartext in HA-Ereignissen und
Sensorattributen und können in Recorder/Backups landen. Gerätesecrets liegen in iOS Keychain und
HA-Konfiguration/Backups. Zugriff und Aufbewahrung begrenzen; keine Geheimnisse/QRs weitergeben.
Für dieses Protokoll wird kein HA-Administrator-Token auf das iPhone kopiert.

## Positiv geprüfte Grenzen

- AES-256-GCM, HKDF-SHA256 mit Richtung-/Request-/Statusbindung, zufällige 96-Bit-Nonces.
- Manipulierte/ungültige v2-Nachrichten und Klartext an v2-Einträgen werden abgewiesen.
- Nonce-/Message-ID-Replays, doppelte Ereignis-IDs und aufgezeichnete v2-Ereignisse nach HA-Neustart
  werden in den Regressionstests abgewehrt.
- QR-Angebote sind kurzlebig, zufällig und nach erfolgreichem Austausch verbraucht.
- Kameraframes bleiben auf dem iPhone; die Modelle sind per SHA-256 festgelegt.
- Torzuordnungen kommen ausschließlich aus HA-Konfiguration. Ein iPhone-Payload darf keine
  `garage_entity_id` vorgeben. Neue Richtungsfelder werden strikt auf Typen, endliche Werte und
  Grenzen geprüft. Es werden keine Cover-Services ausgeführt.

`pip-audit` prüfte am 19.10.2026 die installierten Python-Abhängigkeiten in
`.venv/lib/python3.12/site-packages`: **keine bekannten gemeldeten Schwachstellen**; das editierbare
Projekt selbst wurde vom Paket-Audit übersprungen. Das sagt nichts Vollständiges über Dart-Pakete,
CocoaPods, Betriebssysteme oder die Pakete deiner tatsächlichen HA-Installation aus.

Primärreferenzen:

- [Cryptography: AES-GCM und Nonce-Anforderungen](https://cryptography.io/en/stable/hazmat/primitives/aead/)
- [Home Assistant: Entity-Selektoren](https://www.home-assistant.io/docs/blueprint/selectors/#entity-selector)

## Vor sicherheitsrelevantem Automatikbetrieb

1. Altersprüfung/TTL, Größen-/Ratenlimits und Legacy-Abschaltung gezielt härten und testen.
2. Vertrauenswürdigen QR-Bootstrap sicherstellen und Geheimnisse bei Verdacht neu koppeln.
3. Zusätzliche unabhängige Zutritts- und Tor-Sicherheitstechnik verwenden.
4. Bewegungsheuristik mit fest montiertem iPhone, unverändertem Zoom und realen Ein-/Ausfahrten
   messen. Sie ist kein kalibrierter 3D-Vektor, keine Geschwindigkeit in m/s und kein Hindernissensor.
