# Kennzeichen-Sensoren und Home-Assistant-Automationen

## Übersichtliche Einrichtung

**Einstellungen → Geräte & Dienste → OpenPlate → Konfigurieren** enthält:

- **Kennzeichen verwalten:** hinzufügen, bearbeiten oder löschen. Jedes Kennzeichen
  hat ein eigenes Feld und einen separaten Anzeigenamen. Ohne Leerzeichen oder
  Bindestriche eingeben, z. B. `MÜAB123`; kein `KENNZEICHEN=Name` nötig.
- **iPhone koppeln:** QR-Kopplung.
- **Kamera und Verbindung:** Erkennung, HA-Adresse und Anwesenheitsdauer.

Vorhandene Kennzeichen und Kopplungen werden übernommen. Ä/Ö/Ü sind eigene Zeichen,
keine automatischen A/O/U-Aliase. Die iPhone-App ergänzt das ASCII-OCR-Modell durch
eine lokale Vision-Nachprüfung am Originalausschnitt; Erkennungsqualität und kleine
Umlautpunkte müssen weiterhin in der realen Montage getestet werden.

## Zwei Entitäten je Kennzeichen

| Entität | Zustand | Bedeutung |
|---|---|---|
| Binary-Sensor „KENNZEICHEN detected“ | `on` / `off` | Intern true/false: bestätigt erkannt und zuletzt innerhalb des Timeouts gesehen |
| Sensor „KENNZEICHEN direction“ | `arrival` | Kennzeichen wird über mehrere Frames größer: zur Kamera |
| Richtungssensor | `departure` | Kennzeichen wird kleiner: von der Kamera weg |
| Richtungssensor | `stationary` | Kaum Größen-/Positionsänderung |
| Richtungssensor | `unknown` | Fehlende oder unsichere Richtung, Start oder Anwesenheit abgelaufen |

Mindestens vier gültige Größenmessungen über zwei Sekunden sind nötig.
Einzelne Bounding-Box-Schwankungen sollen nicht auslösen. Bewegung wird lokal auf
dem iPhone berechnet; übertragen werden nur Kennzeichen und kleine Metadaten,
verschlüsselt. Bei fehlendem oder altem App-Support bleibt die Richtung unbekannt.

Die Richtung beschreibt die jüngste Beobachtung und wird beim Not-seen-Timeout
zurückgesetzt. Verschwinden ist **kein** `departure`. Der Binary-Sensor meldet
„kürzlich erkannt“, nicht die tatsächliche Parkposition. Ein fremdes Kennzeichen
schaltet registrierte Kennzeichen nicht ein; jedes hat einen eigenen Zustand.

## Steuerung bleibt bei HA

OpenPlate ruft keine Tor-/Schalteraktionen mehr auf. Alte Zuordnungen/Aktionsoptionen
bleiben gespeichert, werden aber ignoriert; alte Garagen-Sensoren werden entfernt.
Vorhandene Präsenz-Unique-IDs bleiben erhalten. Beim Löschen eines Kennzeichens werden
seine Präsenz-/Richtungsentitäten entfernt; bestehende Automationen dann prüfen.

Für Automationen die Zustandsänderung des **Richtungssensors** auf `arrival` oder
`departure` verwenden. Präsenz kann schon einen Frame früher auf `on` wechseln;
ein reiner off→on-Trigger mit Richtungsbedingung könnte deshalb die Ankunft verpassen.
Die tatsächlichen Entity-IDs deiner Instanz aus der Entitätenliste auswählen.

Im Dashboard lassen sich echter Torstatus, Kennzeichen-Anwesenheit und Richtung
nebeneinander darstellen. Den echten Torstatus liefert die vorhandene cover-Entität,
nicht OpenPlate. Bei andersherum ausgerichteter Kamera kann `arrival` an der Kamera
einer Abfahrt vom Grundstück entsprechen; diese Zuordnung gehört in die Automation.

## Sicherheit und Teststand

Kennzeichen können kopiert werden; ein gekoppeltes iPhone ist kein Beweis für
Fahrzeugidentität. Richtungsschätzung kann durch Perspektive, Zoom und Verdeckung
irren. `departure` beweist keine freie Durchfahrt. Für automatisches Schließen sind
unabhängige Sicherheitssensorik und die Schutzfunktionen des Torantriebs erforderlich.
Zuerst mit einer Benachrichtigung oder Testlast prüfen.

HA-Tests decken separate Kennzeichenfelder, Sensorzustände, Timeout, exakte
Umlautidentitäten, Registry-Bereinigung und ausbleibende Aktoraufrufe ab.
Ein realer iPhone-/Tor-Test steht noch aus.
