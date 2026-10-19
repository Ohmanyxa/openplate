# Garagen und direkte Steuerung

In Home Assistant: **Einstellungen → Geräte & Dienste → OpenPlate → Konfigurieren →
Garagen und direkte Steuerung**. „New garage“ legt eine benannte Garage an;
vorhandene Garagen lassen sich bearbeiten oder löschen. Jede Garage gehört zur
konfigurierten Kamera und erhält eine stabile ID sowie einen Bewegungssensor.
Mehrere Garagen und mehrere registrierte Kennzeichen je Garage sind möglich.
Kennzeichen zuerst unter „Registrierte Kennzeichen“ anlegen.

Pro Garage auswählen:

- Name, Kennzeichen und vorhandenes `cover` oder `switch` als Ziel.
- Kamerarichtung für `arrival`: `approaching` (Kennzeichen wächst) oder `receding`
  (Kennzeichen schrumpft). Die andere Richtung ergibt `departure`.
- Getrennte Aktionen: `open`/`close` für cover, `on`/`off` für switch.
  `none` führt keine Aktion aus. Beispiel: arrival=open, departure=none.
- Direkte Steuerung bewusst aktivieren; standardmäßig deaktiviert.

Es ist keine zusätzliche HA-Automation erforderlich. Der Sensor zeigt die **letzte
bestätigte Bewegung**, nicht die Torposition oder Fahrzeuganwesenheit; nach Neustart
ist er `unknown`. Attribute nennen Kennzeichen, Ziel, Aktivierung und Ergebnis
(`disabled`, `rejected`, `cooldown`, `pending`, `sent`, `unavailable`, `failed`).
`sent` bestätigt nur den HA-Serviceaufruf, nicht die tatsächliche Torbewegung.
Das vorhandene Plate-event unterstützt zusätzlich `arrival` und `departure` mit
`garage_id`. Alte Kennzeichen→Tor-Zuordnungen bleiben reine Metadaten und aktivieren
keine Steuerung. Zum Umstieg eine neue Garage anlegen.

## Auslösegrenzen

Die Größenentwicklung wird bereits lokal auf dem iPhone über mehrere Bounding-Boxes
bestimmt. HA prüft Richtung, Vorzeichen der Größenänderung und Mindestmessumfang.
Unbekannte Kennzeichen und fehlende/unklare Bewegung lösen nicht aus.
Verschlüsselte v2-Verbindung, aktuelle Meldung (höchstens 15 Sekunden Abweichung),
Konfidenz mindestens 0,8 und mindestens drei OCR-Beobachtungen sind Voraussetzungen
für direkte Aktionen. Datum/Uhrzeit müssen auf beiden Geräten stimmen.

Pro Kennzeichen/Garage wird dieselbe Richtung erst nach Richtungswechsel oder dem
Not-seen-Timeout wieder als Ereignis gemeldet. Aktionen haben zusätzlich einen
garagenweiten Mindestabstand von 60 Sekunden; unterdrückte Aktionen werden **nicht**
später nachgeholt. Laufende Aktionen sperren weitere Aktionen dieser Garage.
Verschwinden allein schließt niemals ein Tor. Nicht verfügbare Ziele und Fehler
führen nicht zu automatischen Wiederholungen. Beim Entladen werden Hintergrundtasks
von HA beendet; bereits versandte Gerätebefehle sind nicht rückgängig zu machen.

## Sicherheit

Ein Kennzeichen kann kopiert werden. Verschlüsselung authentifiziert das gekoppelte
iPhone, nicht das Fahrzeug. Die Größenheuristik kann durch Perspektive, Zoom und
Verdeckungen irren. `departure` beweist **keine freie Durchfahrt**. Automatisches
Schließen darf nur mit unabhängiger, funktionsfähiger Sicherheitssensorik des
Torantriebs benutzt werden. Nicht als alleinige Zugangssicherung einsetzen.

Switches müssen echte Ein-/Aus-Ziele sein (z. B. Licht), keine Impulsrelais mit
wechselnder Torfunktion. `turn_on` wäre bei solchen Relais trotz eindeutiger
HA-Aktion kein sicherer Öffnen-Befehl. Für Tore stattdessen ein geeignetes cover
mit expliziten Öffnen-/Schließen-Aktionen verwenden. Kein `toggle` implementiert.

Mehrere Kameras steuern unabhängig: dasselbe Tor nicht parallel in mehreren
OpenPlate-Kameraeinträgen direkt steuern. Cooldown gilt pro Garage, nicht global
über Kameras hinweg. Nach Neustart sind Richtungslatches und Cooldown zurückgesetzt.

Automatisierte Tests prüfen Policy, Optionsflow, Sensor, Entprellung und gemockte
HA-Serviceaufrufe. Echte Tore/Schalter und Montagebedingungen sind vor Ort separat
zu testen, zunächst mit deaktivierter Steuerung oder einer ungefährlichen Testlast.
