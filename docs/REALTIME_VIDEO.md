# iPhone-Livebild mit H.264 und WebRTC

## Einrichtung für ein montiertes iPhone

1. HA-Integration und iPhone-App gemeinsam auf einen Stand mit `camera_webrtc_v1` aktualisieren.
   Die vorhandene Kopplung und Kamera-Unique-ID bleiben erhalten.
2. Die iPhone-App im Vordergrund lassen. Bei gespeicherter Kopplung starten Kamera und
   Erkennung automatisch; Schwarzmodus führt Aufnahme und Erkennung weiter aus.
3. In HA unter **OpenPlate → Konfigurieren → Kamera und Verbindung → Livebild (WebRTC)**
   das Livebild aktivieren. Standard: ausgeschaltet, Ziel 24 FPS, 720p. Alternativ 12/15 FPS
   oder 480p wählen. Die App übernimmt Änderungen beim nächsten Konfigurationsabruf
   innerhalb von etwa 15 Sekunden und startet den gemeinsamen Kamerakanal neu.
4. Die Liveansicht der vorhandenen **Live camera** öffnen. Bei der ersten Verbindung der
   neuen App wird die bestehende Kamera auf WebRTC umgestellt; eine schon geöffnete
   Kameraansicht ggf. schließen und erneut öffnen.

Eine Dashboard-Karte muss die Liveansicht nutzen, um flüssiges Video anzuzeigen:

```yaml
type: picture-entity
entity: camera.DEINE_OPENPLATE_KAMERA
camera_view: live
```

Die Entität aus der eigenen HA-Installation auswählen. Eine normale Standbildvorschau ist
weiterhin nur ein JPEG, das etwa alle fünf Sekunden aktualisiert wird; sie zeigt keine 24 FPS.

## Verarbeitung und Verschlüsselung

Die App verwendet eine einzige native WebRTC-Kameraaufnahme für Vorschau, Videostream und
lokale Erkennung. Ein nativer Renderer hält nur den neuesten Frame. Für die Erkennung wird
bei Bedarf ein BGRA-Bild im eingestellten Prüfintervall ausgelesen; keine Bilddateien und kein
zweiter Kamerazugriff. Die Erkennungsmodelle laufen weiterhin ausschließlich auf dem iPhone.

Browser-Offers, Antworten und ICE-Kandidaten werden über HA vermittelt. Der iPhone-Teil läuft
über den bestehenden gepaarten AES-256-GCM-Kanal mit Geräte-/Sitzungsbindung und Replay-Schutz.
Die Videoübertragung selbst läuft direkt zwischen iPhone und Betrachter mit WebRTC DTLS-SRTP;
es werden keine 24 JPEG-Anfragen pro Sekunde an HA gesendet. HA decodiert kein Livevideo.
Der über die authentifizierte Signalisierung ausgetauschte SDP-Fingerprint bindet den Medienkanal.

H.264 wird über die nativen Codec-Präferenzen gewählt; andere Videocodecs werden für den Sender
nicht angeboten. Das iOS-WebRTC-SDK unterstützt hardwarebeschleunigtes H.264 über VideoToolbox.
Das Ziel ist maximal 24 FPS, mit einer Bitratenobergrenze von 2 Mbit/s bei 720p bzw. 1 Mbit/s
bei 480p je Betrachter. Die Übertragung darf Auflösung/Bildrate bei schwachem Netz reduzieren.
Diese Einstellungen sind keine gemessene Zusicherung für ein bestimmtes Gerät oder WLAN.

Es werden höchstens zwei gleichzeitige Livebetrachter unterstützt. Geschlossene Ansichten,
HA-Neustarts und Kamera-Neustarts schließen die jeweiligen Peer-Verbindungen. Ohne iPhone-
Heartbeat wird der Signalisierungskanal nach 15 Sekunden nicht mehr als verfügbar betrachtet;
die regelmäßige Bereinigung läuft alle fünf Sekunden. Unbeantwortete Offers verfallen nach 30 Sekunden.

## Betrieb und Grenzen

- Die iPhone-App öffnet nach gespeicherter Kopplung Kamera und Erkennung automatisch. Sie muss
  für Dauerbetrieb im Vordergrund bleiben. Hintergrundwechsel oder Sperren stoppt Medien und
  Kamera; beim Zurückkehren startet der angeforderte Betrieb automatisch wieder.
- Neue HA-Integration mit alter iPhone-App behält zunächst die bisherige JPEG-Kamera. Erst eine
  gültige Signalisierungsanfrage der neuen App stellt diese Kamera automatisch auf WebRTC um.
- Das iPhone verwendet keine fest hinterlegten öffentlichen STUN-/TURN-Dienste. Der HA-Browser
  kann die bereits in HA eingerichteten ICE-Server verwenden. Für den ersten Test dieselbe lokale
  Netzwerkumgebung verwenden; Gastnetz-Isolation, VLAN-Regeln und NAT können direkte Verbindungen
  verhindern. Eine zusätzliche TURN-Relay-Infrastruktur wird von OpenPlate nicht bereitgestellt.
- HA-Zugriffsrechte schützen den Kameraaufruf. Die Verbindung zum HA-Browser und dessen Anmeldung
  werden weiterhin durch HA abgesichert; die QR-Vertrauensgrenze bleibt unverändert.
- Keine Aufnahmefunktion und kein RTSP-/HLS-Ausgang. Native WebRTC-Kameras unterstützen hier
  nicht die HLS-basierte HA-Aufnahmefunktion.
- 24 FPS und niedrige Latenz müssen auf dem tatsächlichen montierten iPhone mit paralleler
  Erkennung gemessen werden. Ebenso Temperatur, Dauerbetrieb und WLAN-Stabilität.

## Überprüfung

HA-Tests prüfen gepaarte Signalisierung, Session-/Replay-Schutz, begrenzte Nachrichten und Zuschauer,
Abschalten, Timeout sowie die Umstellung mit stabiler Kamera-ID. Dart-Tests prüfen H.264-Auswahl,
24-FPS-Anforderung, gemeinsame Aufnahme und Freigabe nach Sitzungswechsel. Der HTTP-Interop-Test
überträgt SDP zwischen echtem Dart-Client und dem Python-Handler verschlüsselt. Ein nativer
Simulator-Test prüft Frame-Ausrichtung, BGRA-Farben und das Verwerfen alter Puffer.
Diese Tests messen keine Ende-zu-Ende-Videolatenz eines echten iPhones.

## Kameraansicht

**Kamera starten** öffnet den vollständigen automatischen Betrieb. Einen separaten
Erkennungsbutton gibt es nicht mehr. Oben links führt **Zur Übersicht** zurück und beendet
die aktuelle Kameraaufnahme. Der Statusbereich trennt Erkennung, HA-Verbindung und Livebild;
das letzte bestätigte Kennzeichen bleibt sichtbar. **Schwarzmodus** blendet die Bedienung aus,
**Details** enthält Diagnosewerte. Livebild-Freigabe und Bildqualität bleiben in HA.
