# Projektauftrag: Modulares Open-Source-ALPR-System

## 1. Projektziel

Entwickle die erste Version eines plattformübergreifenden Systems zur automatisatischen Kennzeichenerkennung (Automatic License Plate Recognition, ALPR).

Das System soll vorhandene Kamerahardware nutzen, Fahrzeugkennzeichen lokal erkennen, auslesen und verifizieren sowie Erkennungsereignisse sicher an externe Systeme übertragen.

Die Anwendung soll unabhängig von Home Assistant funktionieren. Home Assistant ist lediglich eine mögliche Integration.

### Zielplattformen

1. **iOS:** iPhone 12 mini als erste mobile Referenzplattform.
2. **Linux:** Raspberry Pi 4/5 mit angeschlossener Kamera.
3. **macOS:** Entwicklungs- und Testumgebung.

Die Architektur muss weitere Plattformen ermöglichen, ohne die gesamte Erkennungspipeline neu implementieren zu müssen.

### Entwicklungsprinzipien

- Open Source
- Offline-first
- Privacy by Design
- Hardwareeffizient
- Modular
- Testbar
- Erweiterbar
- Keine unnötigen Abhängigkeiten
- Keine Cloudpflicht

Die Anwendung soll möglichst wenig CPU-, GPU- und RAM-Ressourcen benötigen.

---

## 2. Technologische Grundlage

Verwende Flutter und Dart für die gemeinsame Anwendungslogik und Benutzeroberfläche.

Hardwareabhängige Funktionen dürfen und sollen nativ implementiert werden.

### Open-Source-Referenzen

**FastALPR**

https://github.com/ankandrew/fast-alpr

**Open Image Models**

https://github.com/ankandrew/open-image-models

**FastPlateOCR**

https://github.com/ankandrew/fast-plate-ocr

Untersuche die tatsächlichen Implementierungen dieser Projekte, bevor du eigene Lösungen entwickelst.

Verwende vorhandene, bewährte Komponenten, sofern diese technisch und lizenzrechtlich geeignet sind.

Prüfe insbesondere die Lizenzen der Modellgewichte und aller eingebundenen Abhängigkeiten.

### Vorgesehene Modelle

Kennzeichendetektion:

`yolo-v9-t-384-license-plate-end2end`

OCR:

`cct-xs-v2-global-model`

Die Modelle müssen über austauschbare Schnittstellen eingebunden werden.

Eine spätere Verwendung eigener Modelle darf keine grundlegende Änderung der Anwendungsarchitektur erfordern.

---

## 3. Systemarchitektur

Entwickle eine klare Trennung zwischen folgenden Komponenten:

### Camera Layer

Verantwortlich für:

- Kamerazugriff
- Kameraauswahl
- Aufnahmeauflösung
- Bildrate
- Belichtung
- Fokus
- Bildorientierung
- Frame-Bereitstellung

Plattformimplementierungen:

- iOS: AVFoundation
- Raspberry Pi: libcamera/Picamera2
- macOS: geeignete native Kamera-API

Die Camera Layer darf keine Kennzeichenerkennung enthalten.

### Preprocessing Layer

Verantwortlich für:

- ROI-Verarbeitung
- Bildskalierung
- Bewegungsdetektion
- Bildqualitätsprüfung
- Crop-Erstellung
- Koordinatentransformationen

Nutze nach Möglichkeit klassische Bildverarbeitung, bevor rechenintensive KI-Inferenz gestartet wird.

### Detection Layer

Verantwortlich für:

- Kennzeichenlokalisierung
- Bounding-Box-Erzeugung
- Detektionskonfidenz
- Zuordnung zum Originalbild

Das Detektionsmodell erhält möglichst nur relevante Bildbereiche.

### OCR Layer

Verantwortlich für:

- Extraktion der Kennzeichenzeichen
- OCR-Konfidenz
- Normalisierung
- Optionale Formatvalidierung

Die OCR soll nach Möglichkeit hochauflösende Crops aus dem ursprünglichen Kameraframe erhalten.

### Temporal Validation Layer

Verantwortlich für:

- Zusammenführung mehrerer Erkennungen
- Vergleich aufeinanderfolgender OCR-Ergebnisse
- Behandlung widersprüchlicher Ergebnisse
- Konfidenzbewertung
- Erkennung abgeschlossener Ereignisse

Eine einzelne OCR-Erkennung darf nicht automatisch als bestätigtes Kennzeichen gelten.

### Event Layer

Verantwortlich für:

- Erzeugung eindeutiger Ereignisse
- Zeitstempel
- Geräteidentität
- Kennzeichenergebnisse
- Ereignisstatus
- Duplikatvermeidung
- Ereignisübertragung

### Integration Layer

Verantwortlich für:

- Lokale Serverkommunikation
- Home-Assistant-Anbindung
- Externe API-Adapter
- Gerätekonfiguration
- Authentifizierung

Die Integrationen dürfen nicht direkt auf die internen KI-Implementierungen zugreifen.

---

## 4. Optimierung für schwache Hardware

Die Anwendung soll ereignisgesteuert arbeiten.

### Idle-Modus

Im Ruhezustand:

- Kamera mit konfigurierbarer Bildrate betreiben.
- ROI überwachen.
- Bewegungsänderungen analysieren.
- Keine permanente KI-Inferenz durchführen, sofern nicht erforderlich.

### Active-Modus

Bei relevanter Bewegung:

1. Frames erfassen.
2. Kennzeichenkandidaten erkennen.
3. Crops erstellen.
4. OCR ausführen.
5. Mehrere Ergebnisse vergleichen.
6. Bestätigtes Ereignis erzeugen.
7. In den Idle-Modus zurückkehren.

### Performanceanforderungen

Implementiere Messungen für:

- Frame-Capture-Zeit
- Preprocessing-Zeit
- Detection-Inferenzzeit
- OCR-Inferenzzeit
- Gesamtlatenz
- CPU-Auslastung
- RAM-Verbrauch
- Verarbeitete Frames pro Sekunde
- Übersprungene Frames
- Anzahl der Inferenzen pro Ereignis

Vermeide unnötige Frame-Kopien und Speicherallokationen.

Nutze einen begrenzten Frame-Puffer und eine definierte Strategie für veraltete Frames.

Die Pipeline darf keine unkontrolliert wachsenden Warteschlangen erzeugen.

---

## 5. Plattformabhängige Inferenz

### iOS

Untersuche die Verwendung von Core ML.

Prüfe, ob die vorgesehenen ONNX-Modelle zuverlässig konvertiert werden können.

Verifiziere:

- Unterstützte Operatoren
- Modell-Eingabeformate
- Modell-Ausgabeformate
- Postprocessing
- Numerische Übereinstimmung mit der ONNX-Referenz
- Tatsächlich genutzte Hardwarebeschleunigung

Nutze Swift für die native Inferenzintegration.

Die Flutter-Anwendung kommuniziert über eine geeignete native Schnittstelle mit dem Inferenzbackend.

Berücksichtige die iOS-Beschränkungen für Kameraaufnahmen im Hintergrund.

Versprich keinen unbeaufsichtigten Hintergrundbetrieb, den iOS nicht unterstützt.

### Raspberry Pi

Verwende zunächst ONNX Runtime als Referenz.

Prüfe anschließend, ob ncnn messbare Vorteile bietet.

Nutze die Kamera über libcamera beziehungsweise Picamera2.

Der Raspberry Pi muss ohne grafische Benutzeroberfläche betrieben werden können.

Die Erkennungslogik darf deshalb nicht von einer laufenden Flutter-Oberfläche abhängen.

### Gemeinsame Schnittstelle

Definiere ein austauschbares Interface für die Erkennungsengine.

Die Anwendung darf keine direkten Abhängigkeiten von einem konkreten Modellformat besitzen.

---

## 6. Kamerakalibrierung

Implementiere eine einfache Einrichtung für fest montierte Kameras.

Der Benutzer soll:

1. Eine Kamera auswählen.
2. Das Livebild betrachten.
3. Einen Erfassungsbereich markieren.
4. Die ROI speichern.
5. Die Erkennung testen können.

Speichere die ROI in normalisierten Koordinaten.

Berücksichtige Änderungen der Kameraauflösung und Bildorientierung.

Die Kalibrierung muss nach einem Neustart erhalten bleiben.

Für V1 ist keine vollständige geometrische Kamerakalibrierung erforderlich.

---

## 7. Benutzeroberfläche

Entwickle eine funktionale Flutter-Oberfläche.

### Dashboard

Anzeige von:

- Kamerastatus
- Verbindungsstatus
- Aktuellem Erkennungszustand
- Letztem Kennzeichenereignis
- Performancekennzahlen

### Kameraansicht

Anzeige von:

- Livebild
- ROI
- Detektions-Bounding-Boxes
- OCR-Ergebnissen
- Konfidenzwerten

### Einstellungen

Konfigurierbar:

- Kamera
- Auflösung
- Bildrate
- ROI
- Detection-Schwellenwert
- OCR-Einstellungen
- Anzahl benötigter Bestätigungen
- Serververbindung

### Debug-Modus

Aktivierbare Anzeige der einzelnen Verarbeitungsschritte.

Der Debug-Modus darf den normalen Betrieb nicht unnötig beeinträchtigen.

---

## 8. Kennzeichenverwaltung

Implementiere eine lokale Verwaltung registrierter Kennzeichen.

Jeder Eintrag soll mindestens enthalten:

- Kennzeichen
- Anzeigename
- Aktivierungsstatus
- Optionalen Beschreibungstext

Unterscheide zwischen:

- Kennzeichen erkannt
- Kennzeichen erfolgreich gelesen
- Kennzeichen mit registriertem Eintrag abgeglichen

Ein Kennzeichenabgleich stellt keine sichere Fahrzeugauthentifizierung dar.

Die Anwendung darf deshalb nicht allein aufgrund eines Kennzeichens eine Garagentoröffnung auslösen.

---

## 9. Netzwerkkommunikation

Entwickle eine plattformunabhängige Kommunikationsschnittstelle.

### Anforderungen

- Lokaler Betrieb ohne Internet
- HTTPS/TLS
- Geräteidentitäten
- Sicheres Pairing
- Authentifizierte Kommunikation
- Ereignis-IDs
- Replay-Schutz
- Konfigurierbare Serveradresse
- Wiederverbindung bei Netzwerkunterbrechungen
- Klare Fehlerbehandlung

Nutze HTTPS als Standard für Ereignisübertragungen.

WebSocket kann später für bidirektionale Echtzeitkommunikation ergänzt werden.

Vermeide eigene kryptografische Verfahren.

Nutze etablierte Bibliotheken und sichere Betriebssystemfunktionen zur Schlüsselverwaltung.

### Ereignisformat

Definiere ein versioniertes, dokumentiertes JSON-Schema.

Beispiel:

```json
{
  "schema_version": 1,
  "event_id": "uuid",
  "device_id": "camera_01",
  "timestamp": "ISO-8601",
  "event_type": "plate.recognized",
  "plate": "KAB1234",
  "confidence": 0.97,
  "observations": 4
}
```

Kennzeichendaten sollen standardmäßig nicht dauerhaft gespeichert werden.

Debug-Bilder dürfen nur nach expliziter Aktivierung gespeichert werden.

---

## 10. Home Assistant

Entwickle die Anwendung nicht als reine Home-Assistant-Integration.

Stelle stattdessen eine generische Schnittstelle bereit, über die externe Systeme Ereignisse empfangen können.

Plane einen Home-Assistant-Adapter, der später:

- Kamerastatus bereitstellt
- Erkannte Kennzeichen meldet
- Ereignisse für Automationen erzeugt
- Verbindungsprobleme anzeigt

Die Steuerung externer Geräte erfolgt ausschließlich über explizite, getrennte Berechtigungs- und Integrationskomponenten.

Kennzeichenerkennung allein darf keine sicherheitsrelevante Aktion autorisieren.

---

## 11. Projektstruktur

Entwickle eine nachvollziehbare Monorepo-Struktur.

Trenne mindestens:

- Flutter-Anwendung
- Gemeinsame Dart-Domänenlogik
- Kameraabstraktionen
- Inferenzabstraktionen
- Plattformimplementierungen
- Netzwerkprotokoll
- Integrationstests
- Dokumentation

Vermeide unnötig komplexe Abstraktionen.

Jede Architekturentscheidung muss einen konkreten technischen Zweck erfüllen.

---

## 12. Tests

Implementiere automatisierte Tests für:

- Kennzeichennormalisierung
- OCR-Ergebnisaggregation
- ROI-Koordinaten
- Ereigniserzeugung
- Duplikatunterdrückung
- Netzwerkfehler
- Konfigurationspersistenz
- Authentifizierungs- und Autorisierungsgrenzen

Erstelle außerdem einen reproduzierbaren Inferenzbenchmark.

Vergleiche Modellvorhersagen mit einer festgelegten Referenzausgabe.

Verwende keine erfundenen Performancewerte.

Kennzeichenerkennung und Torautorisierung müssen getrennt getestet werden.

---

## 13. Dokumentation

Erstelle mindestens:

- README.md
- ARCHITECTURE.md
- DEVELOPMENT.md
- MODEL_INTEGRATION.md
- SECURITY.md

Dokumentiere:

- Systemarchitektur
- Datenfluss
- Verwendete Technologien
- Modellherkunft
- Lizenzbedingungen
- Plattformunterschiede
- Bekannte Einschränkungen
- Installationsanleitung
- Entwicklungsumgebung
- Testverfahren

---

## 14. Vorgehensweise

Arbeite inkrementell.

### Phase 1 – Analyse

Untersuche zunächst die drei Open-Source-Repositories.

Prüfe die tatsächlich verfügbaren Modelle, deren Formate, Lizenzbedingungen und Integrationsmöglichkeiten.

Erstelle anschließend einen konkreten Architekturvorschlag.

### Phase 2 – Referenzpipeline

Implementiere eine funktionierende ALPR-Pipeline auf macOS beziehungsweise einer geeigneten Desktop-Testumgebung.

Nutze zunächst vorhandene Bilder und Videodateien.

Verifiziere die Ergebnisse anhand der ursprünglichen FastALPR-Implementierung.

### Phase 3 – Gemeinsamer Core

Implementiere die Dart-Domänenlogik.

Entwickle Schnittstellen für Kamera, Inferenz und Netzwerk.

Erstelle automatisierte Tests.

### Phase 4 – Flutter-Prototyp

Entwickle die Benutzeroberfläche mit Livebild, ROI-Konfiguration und Debug-Anzeige.

### Phase 5 – iOS

Implementiere die native Kamera- und Inferenzintegration.

Teste auf einem iPhone 12 mini.

### Phase 6 – Raspberry Pi

Implementiere einen headless-fähigen Linux-Runner.

Teste Kamerazugriff, Inferenz und Ressourcenverbrauch.

### Phase 7 – Kommunikation

Implementiere Pairing, sichere Ereignisübertragung und einen einfachen lokalen Testserver.

Erst anschließend sollen Home-Assistant-Adapter und konkrete Geräteintegrationen folgen.

---

## 15. Arbeitsanweisungen

Wichtig:

1. Analysiere zunächst das vorhandene Repository und die verfügbaren Entwicklungswerkzeuge.
2. Überprüfe externe technische Annahmen anhand der tatsächlichen Dokumentation und Implementierung.
3. Verwende bestehende Open-Source-Komponenten, statt funktionierende Algorithmen unnötig neu zu schreiben.
4. Halte plattformabhängigen Code von der gemeinsamen Domänenlogik getrennt.
5. Implementiere keine umfangreichen Funktionen, bevor die grundlegende Inferenzpipeline nachweislich funktioniert.
6. Führe nach jeder Implementierungsphase die relevanten Tests aus.
7. Dokumentiere nicht getestete Funktionen ausdrücklich als ungetestet.
8. Erfinde keine Benchmarks oder unterstützten Hardwarefunktionen.
9. Erhalte eine klare, wartbare Projektstruktur.
10. Berücksichtige Sicherheit und Datenschutz bereits bei der Architektur.

## Erste konkrete Aufgabe

Beginne mit Phase 1 und Phase 2.

Untersuche die angegebenen Open-Source-Projekte und implementiere anschließend eine minimale, tatsächlich ausführbare Kennzeichenerkennung auf der Entwicklungsplattform.

Das erste Ergebnis muss Folgendes ermöglichen:

- Ein Bild laden.
- Kennzeichen lokalisieren.
- Kennzeichen-Crop erzeugen.
- OCR ausführen.
- Erkannten Text ausgeben.
- Bounding Box visualisieren.
- Einzelne Verarbeitungszeiten messen.

Erstelle anschließend eine kurze technische Auswertung der verwendeten Modelle und ihrer Integrationsmöglichkeiten für iOS und Raspberry Pi.

**Priorität hat eine nachweislich funktionierende Erkennungspipeline, nicht eine möglichst umfangreiche Benutzeroberfläche.**