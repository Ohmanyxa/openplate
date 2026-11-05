# Fahrzeugprüfung und geführtes Einlernen

## Ablauf

1. Home-Assistant-Integration und iPhone-App aktualisieren. Die vorhandene Kopplung
   kann weiterverwendet werden. Die App übernimmt die Kennzeichenliste beim
   verschlüsselten Konfigurationsabruf (normalerweise innerhalb von 15 Sekunden).
2. Kennzeichen ausschließlich in HA verwalten; keine zweite Liste auf dem iPhone pflegen.
3. Live-Kamera öffnen und Erkennung starten. Sobald ein registriertes Kennzeichen
   über mehrere Frames bestätigt und einem ausreichend großen, vollständig sichtbaren
   Fahrzeug eindeutig zugeordnet wurde, erscheint **Fahrzeug bestätigen**.
4. Den aktuellen Ausschnitt, das Kennzeichen und Typ/Farbe prüfen, Front oder Heck
   auswählen und ausdrücklich bestätigen. Falsche oder ungeeignete Bilder ablehnen.
   Aufnahmen verfallen nach 15 Sekunden; anschließend erneut aufnehmen.
5. Während der ersten Nutzungen Referenzen sammeln. Ein Kennzeichen allein trainiert
   niemals ein Profil. Es werden keine unbestätigten Aufnahmen selbstständig übernommen.
6. Unter **Einstellungen → Fahrzeugprofile & Einlernen** den Fortschritt prüfen.
   Der automatische Vergleich ist erst nach mindestens sechs bestätigten Referenzen,
   Front-/Heckansicht und drei zeitlich getrennten Aufnahmegruppen aktivierbar.
   Gruppen haben mindestens 30 Sekunden Abstand. Dies ist eine Mindestregel für den
   Ablauf, kein Nachweis für echte unabhängige Fahrten oder ausreichend vielfältige Daten.
7. **Automatischen Vergleich aktivieren** bewusst bestätigen. Danach entfällt die
   manuelle Bestätigung; die Referenzen bleiben unverändert. Neue Erscheinung oder
   falsches Profil: ausdrücklich zurücksetzen und erneut einlernen.

Maximal zwölf Referenzen je Kennzeichen. Die Mindestzahl ist keine Sicherheits-
oder Genauigkeitsgarantie. Möglichst echte Ankunfts-/Abfahrtssituationen, unterschiedliche
Entfernungen und Lichtbedingungen sammeln. Erste Automationen nur mit Testlast/Benachrichtigung prüfen.

## Lokale Verarbeitung

- Vorhandene YOLO-Kennzeichendetektion und PaddleOCR Latin bleiben erhalten.
- `vehicle-detection-0200` findet den Fahrzeugkörper. Kennzeichen müssen zu mindestens
  95 % innerhalb genau eines Fahrzeugbereichs liegen; mehrere passende Fahrzeuge oder
  mehrere Kennzeichen im selben Bereich ergeben keinen positiven Nachweis.
- `vehicle-attributes-recognition-barrier-0039` schätzt vier Typen und sieben Farben.
- `vehicle-reid-0001` (OSNet) erzeugt einen 512-dimensionalen Merkmalsvektor.
- Nur bekannte Kennzeichen lösen die Zusatzanalyse aus; höchstens zwei Fahrzeug-
  Zuordnungen je Frame werden beschrieben. Kein zweiter Frame-Upload und kein HA-ML-Server.

Für die erste Version gilt: Typ-Konfidenz mindestens 0,7, Farb-Konfidenz mindestens 0,6.
Im automatischen Modus müssen Typ und Farbe passen und mindestens drei verschiedene,
aufeinanderfolgende Auswertungen (höchstens drei Sekunden Abstand) die Cosinusähnlichkeit
0,88 zu einer bestätigten Referenz erreichen. Fehlende Daten ergeben `unknown`.
Diese Werte sind **nicht für deine Montage kalibriert**. Das Attributmodell wurde
primär für Frontansichten dokumentiert; Heckansichten, Dunkelheit und Verdeckungen
können unzuverlässig sein oder zu Ablehnungen führen. Das ist zunächst Testbetrieb.

Während des Einlernens bestätigt ein Mensch einen aktuellen Ausschnitt. Für die
folgenden höchstens 30 Sekunden gilt diese Bestätigung nur bei erneut passender
Erscheinung und Attributen. Hintergrundwechsel/Erkennungsstopp setzt diese Freigabe zurück.
Ein automatisches Profil wird niemals durch neue Beobachtungen weitertrainiert.

## Datenhaltung

Vorschaubilder bleiben kurzzeitig im Arbeitsspeicher. Dauerhaft gespeichert werden
nur bestätigte Merkmalsvektoren, Typ/Farbe, Zeitpunkte, Ansichtslabel und Modus im
iOS-Schlüsselbund. Die Profile sind an Gerät, Webhook und Kopplungsschlüssel gebunden.
Erneutes Koppeln/Schlüsselrotation erfordert deshalb erneutes Einlernen; alte Scope-
Daten sind nicht automatisch für den neuen Schlüssel nutzbar. Beim Synchronisieren
entfernter HA-Kennzeichen werden ihre Referenzwerte im bisherigen Scope geleert.

Weder Fahrzeugbilder noch Vektoren gehen an HA. Nur diese kleine Metadatenstruktur
wird nach authentifizierter Aushandlung von `vehicle_v1` verschlüsselt übertragen:

```json
{"status":"match","mode":"comparison","type":"car","color":"white","similarity":0.94,"reference_count":6}
```

Das ist eine Aussage des gekoppelten iPhones, kein kryptografischer Beweis für
Kameraherkunft, physisches Fahrzeug oder ein echtes Kennzeichen.

## Home Assistant und Automationen

Jedes registrierte Kennzeichen erhält zusätzlich einen Enum-Sensor **vehicle match**:

| Zustand | Bedeutung |
|---|---|
| `unknown` | Keine ausreichende Fahrzeugprüfung oder Kennzeichen nicht mehr gesehen |
| `enrollment_required` | Einlernen/manuelle Bestätigung nötig |
| `confirmed` | Aktueller Fall im geführten Modus ausdrücklich bestätigt |
| `match` | Automatischer Referenzvergleich über mehrere Frames positiv |
| `mismatch` | Typ/Farbe oder Vergleich passen nicht |

Die vorhandenen Anwesenheits- und Richtungssensoren behalten ihre bisherige Bedeutung.
**Eine bestehende Automation, die allein auf Anwesenheit öffnet, berücksichtigt die neue
Fahrzeugprüfung nicht automatisch!** Im geführten Testbetrieb auf `confirmed`, nach
Umstellung auf `match` reagieren bzw. diese als zusätzliche Bedingung verlangen.
Da der Fahrzeugvergleich später als die reine OCR fertig sein kann, nicht ausschließlich
auf den ersten off→on-Wechsel des Anwesenheitssensors triggern.

OpenPlate steuert keine Tore oder Schalter. Zeitfenster und zusätzliche Freigabeschichten
sind absichtlich nicht Bestandteil dieser Umsetzung. Sicherheitssensorik des Tors bleibt
unabhängig davon erforderlich. Fotos/Displays eines passenden Fahrzeugs oder sehr ähnliche
Fahrzeuge können visuelle Vergleiche täuschen; dies ist keine sichere Zugangsauthentifizierung.

## Modellherkunft und Prüfung

Quellmodelle aus Intels Open Model Zoo, mit dessen SHA-384-Prüfsummen heruntergeladen:

- [vehicle-detection-0200](https://github.com/openvinotoolkit/open_model_zoo/tree/master/models/intel/vehicle-detection-0200), Apache-2.0.
- [vehicle-attributes-recognition-barrier-0039](https://github.com/openvinotoolkit/open_model_zoo/tree/master/models/intel/vehicle-attributes-recognition-barrier-0039), Apache-2.0.
- [vehicle-reid-0001](https://github.com/openvinotoolkit/open_model_zoo/tree/master/models/public/vehicle-reid-0001), MIT (Kaiyang Zhou).

Die drei ONNX-Dateien (zusammen ca. 18 MB) werden mit der App gebündelt. Die Intel-IR-
Modelle wurden nach konstantem Falten konvertiert; der nicht standardisierte
DetectionOutput-Operator wurde durch rohe SSD-Ausgaben ersetzt. Swift übernimmt
CENTER_SIZE-Decodierung und NMS mit Hintergrundklasse 1.

[Exportskript](../scripts/prepare_vehicle_models.py), inklusive Quellprüfsummen und numerischem
Vergleich der konvertierten Köpfe mit OpenVINO an deterministischem Testinput:

```bash
uvx --from 'uv>=0.9,<1' uv run --no-project --python 3.12 \
  --with openvino2onnx==1.1.0 --with onnx==1.18.0 --with 'protobuf<5' \
  --with openvino --with onnxruntime python scripts/prepare_vehicle_models.py
```

Konvertierte Graphreihenfolgen und Dateihashes können beim Export variieren; die
Quellgewichte sind fest gepinnt. Bei Änderungen am ReID-Modell/Vorverarbeitung muss
die Profil-Modellversion erhöht werden, damit alte Vektoren nicht falsch verglichen werden.

Automatisierte Tests prüfen Zustandsübergänge, Bestätigung, Ablauf, Persistenz,
Profilbindung, getrennte HA-Sensoren, verschlüsselten HTTP-Roundtrip und native
ONNX-Inferenz. Physische iPhone-12-mini-Messungen, Nacht-/Wettertests und gezielte
Täuschungsversuche sind noch offen. Benchmarkwerte aus Fahrzeug-ReID-Forschung
sind keine gemessene Einbruchsschutzrate für diese Anwendung.
