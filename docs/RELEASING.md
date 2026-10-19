# Versionen veröffentlichen

Im Repository-Hauptverzeichnis ausführen. Das Skript läuft mit Python 3.9 oder neuer; eine eigene
Python-Umgebung für das Skript ist nicht nötig.

## Vorschau — verändert und veröffentlicht nichts

```bash
python3 scripts/release.py 0.8.0
```

Ohne Versionsangabe wird die nächste Patch-Version vorgeschlagen, z. B. `0.7.0 → 0.7.1`.
Für neue Funktionen die gewünschte Minor-Version ausdrücklich angeben, etwa `0.8.0`.

## Veröffentlichen — ein Befehl

Bei sauberem Arbeitsstand:

```bash
python3 scripts/release.py 0.8.0 --publish
```

Noch nicht committete Änderungen ausdrücklich mitnehmen:

```bash
git status --short
python3 scripts/release.py 0.8.0 --publish --include-working-tree
```

**`--include-working-tree` veröffentlicht ALLE nicht ignorierten Änderungen im Repository**, auch
bereits gestagte Änderungen und neue Dateien. Vorher die Vorschau und `git diff` kontrollieren.
Keine Schlüssel, Zertifikate, privaten Kennzeichen-Testbilder oder sonstige vertrauliche Dateien
einchecken. Der Schalter ist kein automatischer Geheimnis- oder Sicherheitscheck.

Eigene Release-Notizen optional angeben:

```bash
python3 scripts/release.py 0.8.0 --publish --include-working-tree \
  --notes docs/releases/v0.8.0.md
```

Ohne `--notes` verwendet das Skript eine vorhandene `docs/releases/vX.Y.Z.md`, andernfalls generiert
GitHub die Release-Notizen aus den Commits. Bei funktionalen Änderungen und Sicherheitsgrenzen sind
eigene Notizen empfehlenswert. Zum Beispiel bleiben die Befunde aus
[der Sicherheitsprüfung](SECURITY_REVIEW_2026-10-19.md) offen, bis sie gezielt behoben wurden;
erfolgreiche Tests ersetzen kein Sicherheitsaudit und keine Messung am montierten iPhone.

## Was automatisch passiert

1. Versionen in `pyproject.toml`, Flutter-`pubspec.yaml`, HA-`manifest.json` und dem eigenen Eintrag in
   `uv.lock` prüfen und gemeinsam erhöhen. Die iPhone-Buildnummer wird um eins erhöht; Abhängigkeiten
   werden nicht aktualisiert.
2. Branch `main`, GitHub-Remote, Git-Identität, Anmeldung und Remote-Vorlauf prüfen. Kein automatischer
   Branchwechsel, Pull, Rebase oder Überschreiben fremder Änderungen.
3. Python-Lint/Tests, HA-Tests gegen die im Projekt verwendete HA-Version, Flutter-Analyse/Tests und
   einen unsignierten iOS-Release-Build ausführen. Flutter muss die vorhandene Lockdatei akzeptieren.
4. Verhindern, dass während der Tests geänderte Dateien unbemerkt mitcommittet werden.
5. Release-Commit erstellen und `main` ohne Force-Push hochladen.
6. Auf **CI und HACS-Validierung genau dieses Commits** warten. Der GitHub-CI-Lauf enthält auch den
   echten verschlüsselten Dart/HA-HTTP-Rundlauf. Fehlende, fehlgeschlagene oder übersprungene Workflows
   geben den Release nicht frei.
7. Erst danach das Tag `vX.Y.Z` erstellen/pushen und ein reguläres GitHub-Release als „Latest“ anlegen.

HACS bietet das veröffentlichte Release anschließend als Update an. In Home Assistant muss es noch
installiert und HA neu gestartet werden. Die iPhone-App muss separat signiert und installiert werden;
das Skript erstellt weder ein signiertes IPA noch eine TestFlight-Veröffentlichung. Native
Simulator-Modelltests und Tests an der echten Kamera bleiben separate, in der App-README beschriebene
Prüfungen; sie werden durch dieses Release-Skript nicht automatisch durchgeführt.

## Voraussetzungen

- `git`, Git-Name/E-Mail und Schreibzugriff auf `origin`; `origin` muss auf GitHub zeigen.
- GitHub CLI `gh`, angemeldet mit Schreibzugriff auf das Repository: `gh auth login`.
- Aktuelles `uv` (mindestens 0.9) oder `uvx`. Bei einer alten Systeminstallation verwendet das Skript
  automatisch `uvx --from 'uv>=0.9,<1' uv`.
- Flutter, für den normalen Lauf macOS mit eingerichtetem Xcode und CocoaPods.
- Netzverbindung zum Installieren der Testumgebungen und für GitHub. Die GitHub-Workflows `ci.yml`
  und `hacs.yml` müssen aktiv sein und bei einem Push auf `main` starten.
- Keine parallelen Änderungen an diesem Arbeitsstand während des Release-Laufs.

Nur bewusst ohne lokalen iOS-Build, beispielsweise auf Linux:

```bash
python3 scripts/release.py 0.8.0 --publish --skip-ios-build
```

Alle anderen Prüfungen bleiben aktiv. Das ist kein Nachweis eines erfolgreichen iOS-Builds.

## Nach einem Fehler fortsetzen

Das Skript setzt **keine Dateien zurück**, löscht keine Commits und verschiebt keine bestehenden Tags.
Je nach Fehler sind die Versionsdateien bereits erhöht, ein Commit bereits erstellt oder `main`
bereits gepusht. Nach erfolgreicher Tag-Erstellung kann auch das Tag schon auf GitHub existieren.
Ein Fehler nach dem API-Aufruf kann bedeuten, dass der Release bereits veröffentlicht wurde;
`--resume` erkennt einen passenden bereits veröffentlichten Release ohne ihn zu verändern.

1. Meldung, `git status` und ggf. den verlinkten GitHub-Lauf prüfen.
2. Ursache beheben. Falls CI fehlgeschlagen ist, Fehler committen oder den Lauf neu starten.
3. Für die **bereits vorbereitete Version** fortsetzen, ohne die Buildnummer erneut zu erhöhen:

```bash
python3 scripts/release.py 0.8.0 --resume --publish
```

Bei absichtlich noch uncommitteten Korrekturen zusätzlich `--include-working-tree` verwenden. Das geht
nur, solange das Tag noch nicht auf einen anderen Commit festgelegt wurde. Bereits veröffentlichte
oder auf einen anderen Commit zeigende Tags werden nie überschrieben: dafür eine neue Version wählen.
Wenn der Fehler vor der Versionsänderung auftrat, den ursprünglichen Befehl ohne `--resume` wiederholen.

Standardmäßig wird bis zu 30 Minuten auf GitHub-Prüfungen gewartet; mit `--timeout 3600` ist das
anpassbar. Ein lokales Lock verhindert zwei gleichzeitige Release-Läufe in diesem Checkout. Nach
einem harten Prozessabbruch eine angezeigte `.git/openplate-release.lock` erst manuell entfernen,
wenn der darin genannte Prozess nachweislich nicht mehr läuft.

Alle Optionen: `python3 scripts/release.py --help`.
