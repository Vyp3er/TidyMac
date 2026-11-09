# TidyMac

TidyMac räumt auf Knopfdruck oder einmal am Tag automatisch deinen Home-Ordner oder ausgewählte Ordner auf: sortieren, Ordner anlegen, verschieben, umbenennen, Duplikate finden, Aufräum- und Löschvorschläge machen. Oberster Grundsatz: **lieber etwas nicht sortieren, als etwas kaputt zu machen.** Nichts passiert ohne Vorschau und Bestätigung, nichts wird überschrieben, „Löschen“ heißt immer Papierkorb, und jeder Lauf lässt sich rückgängig machen.

> **Einfach nur benutzen?** Lade die fertige App unter [Releases](https://github.com/Vyp3er/TidyMac/releases/latest) herunter und folge der [Installationsanleitung](INSTALL.md). Du brauchst einen Mac mit Apple Silicon und macOS 15 oder neuer. Claude ist optional: über dein eigenes Claude-Abo (Pro oder Max), einen API-Key oder gar nicht.

TidyMac gehört zu [MacTweaks](https://github.com/Vyp3er/MacTweaks), zusammen mit KeyFlow, MacBuddy und NotchIsland. Dort gibt es auch einen Befehl, der alle vier Apps auf einmal installiert.

- Swift 5 + SwiftUI (AppKit wo nötig), macOS 15 oder neuer, Apple Silicon
- Kein App Sandbox
- Kernlogik als Swift Package `TidyCore` mit 83 Unit-Tests; App-Target `TidyMac` im Xcode-Projekt

## Projektstruktur

```
TidyMac/
├── TidyMac.xcodeproj          Xcode-Projekt (App-Target, bindet TidyCore lokal ein)
├── TidyMac/                   App: SwiftUI-Oberfläche, Menüleiste, Einstellungen, Systemdienste
│   ├── App/                   App-Einstieg, AppModel (Zustand), Debug-Optionen
│   ├── Views/                 Aufräumen/Vorschau, Duplikate, Vorschläge, Prüfung, Verlauf, Einstellungen
│   └── Services/              Schlüsselbund, Anmeldeobjekt, Festplattenvollzugriff, Mitteilungen, Hintergrund
└── TidyCore/                  Swift Package (ohne UI)
    ├── Sources/TidyCore/
    │   ├── Protection/        Schutzlogik: Projekte, Tabu-Bereiche, Cloud, Verweise, zusammengehörige Ordner
    │   ├── Scan/              Paralleler Scanner, Ordnerstruktur-Index, Textauszüge
    │   ├── Rules/             Regel-Engine, eingebaute Regeln, Zuordnung zu vorhandenen Ordnern
    │   ├── AI/                AIProvider: Claude-Code-CLI (Abo) und Anthropic API, Prompt, Cache, Datenschutzfilter
    │   ├── Planning/          Hybrid-Planer (Dry-Run), Umbenennen
    │   ├── Execution/         Ausführen, SQLite-Journal, Rückgängig, ZIP-Archiv, Papierkorb
    │   ├── Duplicates/        Größe → Teil-Hash → SHA-256
    │   ├── Cleanup/           Aufräum-Vorschläge, Löschvorschläge (alte Dateien, KI-Bewertung)
    │   └── Background/        FSEvents-Watcher, Hintergrund-Modus, tägliche Automatik
    ├── Sources/tidyctl/       Kommandozeilen-Werkzeug für Probeläufe in Test-Ordnern
    └── Tests/TidyCoreTests/   Unit-Tests (laufen ausschließlich in temporären Test-Ordnern)
```

## Bauen

Voraussetzung: Xcode 16 oder neuer (getestet mit Xcode 27 / Swift 6.4).

Falls `xcode-select` auf die Command Line Tools zeigt (Fehlermeldung „requires Xcode“), entweder einmalig umstellen:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

oder jedem Befehl `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` voranstellen.

App bauen (Release):

```bash
xcodebuild -project TidyMac.xcodeproj -scheme TidyMac -configuration Release -derivedDataPath build/DerivedData build
```

Danach `build/DerivedData/Build/Products/Release/TidyMac.app` nach `/Programme` kopieren und starten:

```bash
cp -R build/DerivedData/Build/Products/Release/TidyMac.app /Applications/
```

Release-ZIP für GitHub bauen (sauberer Release-Build, Signaturprüfung, `build/release/TidyMac-<Version>.zip` mit SHA-256):

```bash
scripts/make_release.sh
```

Das App-Symbol erzeugt `scripts/make_icon.swift` (`swift scripts/make_icon.swift <Ausgabeordner>`).

Tests (wahlweise per SwiftPM oder xcodebuild):

```bash
cd TidyCore && swift test
```

```bash
cd TidyCore && xcodebuild -scheme TidyCore-Package -destination 'platform=macOS' test
```

### Signierung

Das Projekt signiert standardmäßig ad hoc („Sign to Run Locally“), damit es ohne Apple-Developer-Konto baut. Nachteil: macOS bindet den Festplattenvollzugriff und das Anmeldeobjekt an die Signatur – nach jedem Neubau kann die Freigabe erneut nötig sein. Mit eigenem (auch kostenlosem) Team bleibt sie stabil:

```bash
xcodebuild -project TidyMac.xcodeproj -scheme TidyMac -configuration Release -derivedDataPath build/DerivedData DEVELOPMENT_TEAM=DEINTEAMID CODE_SIGN_IDENTITY="Apple Development" build
```

## Berechtigungen

| Berechtigung | Wofür | Wie |
|---|---|---|
| Festplattenvollzugriff | Alle Ordner sehen, Finder-Favoriten und Dock-Einträge lesen (für den Verweis-Schutz) | Onboarding → „Systemeinstellungen öffnen“ → Datenschutz & Sicherheit → Festplattenvollzugriff → TidyMac aktivieren, App neu starten. Ohne Freigabe fragt macOS einzeln nach Schreibtisch/Dokumente/Downloads. |
| Mitteilungen | Zusammenfassung des Hintergrund-Modus mit „Rückgängig“-Knopf | Wird beim Einschalten des Hintergrund-Modus angefragt |
| Anmeldeobjekt | Autostart beim Login | Einstellungen → Allgemein → „Beim Anmelden starten“ (ggf. in Systemeinstellungen → Allgemein → Anmeldeobjekte freigeben) |

Einstellungen, Journal und KI-Cache liegen in `~/Library/Application Support/TidyMac/` (`settings.json`, `journal.sqlite`, `ai-cache.sqlite`). Ein Anthropic-API-Key wird ausschließlich im Schlüsselbund gespeichert.

## Bedienung

1. **Scan** – „Alles (Home-Ordner)“ oder „Ausgewählte Ordner“ (Liste, „Ordner hinzufügen …“ oder per Drag & Drop). Der Scan liest nur und läuft parallel mit Fortschrittsanzeige.
2. **Vorschau (Dry-Run)** – Liste aller geplanten Aktionen, gruppiert nach Zielordner, mit Begründung, Herkunft (Regel/Claude/Manuell) und Konfidenz. Einzelne Aktionen oder ganze Gruppen an-/abwählen, Ziel oder neuen Namen ändern, Filter „Unsicher“, „Mit Warnung“, „Von Claude“. Umschaltbar auf einen Vorher/Nachher-Baum; neue Ordner sind markiert. Aktionen unter der Vorauswahl-Schwelle (Standard 70 %) oder mit Warnung sind abgewählt.
3. **Ausführen** – nur nach Bestätigung. Jede Aktion wird direkt davor erneut geprüft (Schutz, geöffnet?, Ziel erlaubt?). Namenskonflikte werden nie überschrieben, sondern Finder-artig umbenannt („Name 2.pdf“).
4. **Rückgängig** – Banner direkt nach dem Lauf, Verlauf mit ganzen Läufen oder einzelnen Aktionen. Angelegte Ordner werden beim Rückgängigmachen wieder entfernt, wenn sie leer sind. Ist der ursprüngliche Platz inzwischen belegt, wird nicht überschrieben, sondern daneben eindeutig benannt.

Weitere Bereiche: **Duplikate**, **Aufräum-Vorschläge**, **Löschen** (alte Dateien, die Claude für entbehrlich hält, jede einzeln zu bestätigen), **Zur Prüfung** (aus Hintergrund-Modus und Automatik), **Geschützt** (was der letzte Scan geschützt hat und warum), **Verlauf**.

**Menüleiste:** „Downloads aufräumen …“, „Ausgewählte Ordner aufräumen …“ (öffnen jeweils die Vorschau), „Zur Prüfung“, „Letzten Lauf rückgängig“, Hintergrund-Modus an/aus, Automatik an/aus, Einstellungen.

## Schutzregeln – was niemals verschoben oder verändert wird

Die Schutzlogik (`TidyCore/Protection`) wird beim Scan, beim Planen **und** unmittelbar vor jeder einzelnen Aktion angewendet.

**Projektordner sind unteilbar.** Ein Ordner ist ein Projekt, wenn er einen dieser Marker enthält: `.git`, `.hg`, `.svn`, `package.json`, `Cargo.toml`, `CMakeLists.txt`, `Makefile`, `pyproject.toml`, `requirements.txt`, `setup.py`, `Pipfile`, `Package.swift`, `*.xcodeproj`, `*.xcworkspace`, `go.mod`, `pom.xml`, `build.gradle(.kts)`, `Gemfile`, `composer.json`, `pubspec.yaml`, `Dockerfile`, `.vscode`, `.idea`, `node_modules`, `venv`/`.venv`, `pyvenv.cfg`, `*.sln`/`*.csproj`, Unity- und Arduino-Projekte, LaTeX-Projekte (mehrere `.tex`-Dateien oder `.tex` + `.bib`/`.cls`/`.sty`) und weitere (eigene Marker sind einstellbar). Der Inhalt eines Projekts wird nie angefasst (auch nicht für Duplikate), der Ordner selbst wird standardmäßig nicht verschoben. Ein Ordner, der irgendwo ein Projekt enthält, wird ebenfalls nicht als Ganzes bewegt. Standardordner wie Downloads werden nicht durch eine lose `requirements.txt` zum „Projekt“ – dort zählen nur Versionsverwaltungs-Ordner.

**Zusammengehörige Ordner** (Fotoserie, Musikalbum, Projektabgabe/Bewerbung, entpacktes Archiv, Website mit relativen Links) werden höchstens als Ganzes bewegt, nie auseinandergenommen; es werden auch keine Dateien in sie hineinsortiert. Gespeicherte Webseiten (`Seite.html` + `Seite_files`) bleiben zusammen liegen.

**Tabu:** `~/Library`, versteckte Dateien und Ordner, Systemordner (`/System`, `/Library`, `/usr`, …), `/Applications` und `~/Applications`, App-Bundles und Pakete (`.app`, `.photoslibrary`, `.musiclibrary`, `.fcpbundle`, `.logicx`, VMs, …; nur Dokument-Pakete wie `.pages`/`.key`/`.numbers`/`.rtfd` werden wie Dateien behandelt), von Apps verwaltete Ordner (`~/Music/Music`, Lightroom, Zoom, Parallels, …) und Ordner mit App-Datenbanken (`.sqlite`, `.db`, `.lrcat`, …), symbolische Links und Aliasse, gerade geöffnete Dateien (offene Dateien aller eigenen Prozesse wie bei `lsof`, plus Office-Sperrdateien), unfertige Downloads (`.crdownload`, `.part`, …).

**Cloud-Ordner im Sync** (iCloud Drive inkl. „Schreibtisch & Dokumente“, Dropbox, OneDrive, Google Drive, Nextcloud, …; erkannt an Ort, Name und Marker-Dateien) werden nur nach expliziter Freigabe in den Einstellungen angefasst.

**Verweise:** Ordner, auf die Dock-Einträge, Finder-Favoriten, Symlinks oder Aliasse zeigen, werden nur mit Warnung vorgeschlagen und sind standardmäßig abgewählt.

**Eigene Ausschlussliste:** Ordner und Muster (`*.psd`, `~/Documents/Steuer/*`) in Einstellungen → Schutz.

## Sortierlogik (Hybrid)

**Downloads komplett nach „Dokumente“ (Standard):** Downloads ist ein Eingangsordner, der leer werden soll. Jede Datei daraus bekommt einen Platz unter `~/Documents`, auch Bilder, Videos und Musik. Fehlende Überordner legt TidyMac an. Claude wählt thematische Ordner wie `Finanzen/Rechnungen/2025`, `Uni/Analysis`, `Wohnung`, `Bewerbungen` oder `Reisen` und bevorzugt vorhandene Ordner. Einen neuen Überordner darf es auch für eine einzelne Datei anlegen, tiefere neue Ebenen erst, wenn mehrere Dateien hineinpassen. Kann Claude nichts zuordnen (oder ist die KI aus), greift eine Kategorie nach Dateiart: `Unterlagen`, `Bilder` (mit `Bildschirmfotos/<Jahr>` und `Fotos/<Jahr>`), `Videos`, `Audio`, `Tabellen`, `Präsentationen`, `Bücher`, `Archive`, `Code`, `Sonstiges`. Ordner aus Downloads wandern als Ganzes mit (Fotoserien → `Bilder`, Alben → `Audio/Alben`), gespeicherte Webseiten zusammen mit ihrem `_files`-Ordner nach `Websites`. Jede Verschiebung aus Downloads ist vorausgewählt. Abgewählt bleiben nur Fälle mit Warnung: Projektordner (Git, Node, Python …) und Ordner, die einen Projektordner enthalten, werden nur als Ganzes nach `Dokumente/Projekte` angeboten, ihr Inhalt wird nie angefasst. Dazu kommen Dateien, die im Ziel schon identisch liegen. Installer, bereits entpackte Archive, Torrent-Dateien, Reste, abgebrochene Downloads und Kopien bereits installierter Apps stehen in derselben Vorschau als „In den Papierkorb“, die jeweils nur mit eigenem Häkchen ausgeführt werden („Alle auswählen“ kreuzt sie nie an). Liegt „Dokumente“ in iCloud („Schreibtisch & Dokumente“), ist es als Ziel trotzdem erlaubt; als Quelle bleibt der Cloud-Ordner geschützt. Einstellbar unter Einstellungen › Allgemein (auch für weitere Ordner wie den Schreibtisch und mit anderem Zielordner).

Für alle anderen Ordner gilt:

1. **Schnelle Regeln zuerst** – eigene Regeln haben Vorrang, dann eingebaute: Bildschirmfotos (Spotlight-Flag oder Name) → `~/Pictures/Bildschirmfotos/<Jahr>` (bzw. dein eingestellter Bildschirmfoto-Ort oder ein vorhandener „Screenshots“-Ordner), Bildschirmaufnahmen, Installer (`.dmg`, `.pkg`) → `~/Downloads/Installer`, Rechnungen, Kontoauszüge, Gehaltsabrechnungen → `~/Documents/Finanzen/…/<Jahr>`, E-Books, Schriften, Kamerafotos (EXIF/Name) → `~/Pictures/Fotos/<Jahr>`, 3D-Modelle, sowie unsicherere Kategorien (Bilder, Videos, Audio, Archive, Code). Das Jahr kommt aus dem Aufnahmedatum, einem Datum im Dateinamen oder dem Erstellungsdatum. Herkunft (`WhereFroms`/Quarantäne-Domain) ist in eigenen Regeln nutzbar.
2. **KI nur bei Unklarem** – ist keine Regel sicher genug (Standard: ≥ 85 %), bekommt Claude Name, Pfad, Metadaten, ggf. Textauszug und die vorhandene Ordnerstruktur und schlägt Zielordner, Beschreibung für den neuen Namen und Konfidenz vor.
3. **Bestehende Struktur respektieren** – vorhandene Ordner werden bevorzugt, auch unter anderem Namen („Screenshots“ statt „Bildschirmfotos“, „Invoices“ statt „Rechnungen“). Neue Ordner der KI nur, wenn mehrere Dateien hineinpassen (sonst nächster vorhandener Elternordner), höchstens 3 neue Ebenen. Ziele in Projekten, `~/Library`, versteckten oder geschützten Ordnern werden verworfen. Liegt im Ziel schon eine identische Datei, wird die Aktion abgewählt und auf „Duplikate“ verwiesen.
4. **Eigene Regeln** – Einstellungen → Regeln, z. B. „Dateiendung ist pdf UND Dateiname enthält Rechnung → `~/Documents/Finanzen/Rechnungen/{year}`“. Platzhalter: `{year} {month} {day} {date} {yearMonth} {name} {ext} {kind} {domain}`.

**Umbenennen:** Nur nichtssagende Namen („Scan_0012.pdf“, „IMG_4831.jpg“, „Dokument (3).docx“, reine Nummern/IDs) werden nach dem Schema (Standard `{date} {description}`) umbenannt, z. B. „2025-03-14 Rechnung Telekom Mobilfunk.pdf“. Fotos ohne Beschreibung werden optional zu „2025-03-14 IMG_4831.jpg“. Sinnvolle Namen bleiben unverändert. Modus „Nur umbenennen“ in der Scan-Leiste.

## KI-Anbindung

### Gewählter Weg: Claude Code CLI mit deinem Pro-Abo

TidyMac ruft die lokal installierte, **unveränderte** Claude-Code-CLI im Headless-Modus auf, angemeldet mit deinem claude.ai-Konto. Laut Anthropics Rechtshinweisen zu Claude Code ist der OAuth-/Abo-Login für die normale Nutzung von Claude Code durch Abonnenten gedacht. Nicht erlaubt ist, dass Drittanbieter-Apps einen claude.ai-Login anbieten oder Abo-Zugangsdaten/Tokens abgreifen. TidyMac fasst deshalb keine Zugangsdaten an: Es startet nur dein eigenes `claude`-Programm, so als würdest du es im Terminal aufrufen. Jede Person, die TidyMac nutzt, braucht dafür ein eigenes Claude-Abo und eine selbst installierte und selbst angemeldete Claude-Code-Installation. TidyMac teilt oder vermittelt keine Zugänge. Wer TidyMac beruflich oder für andere einsetzt, nimmt besser den API-Key-Weg.

Aufruf (Kern: `TidyCore/Sources/TidyCore/AI/ClaudeCLIProvider.swift`):

```
claude -p --output-format json --json-schema <Schema> --system-prompt <TidyMac-Prompt>
       --tools "" --strict-mcp-config --safe-mode --disable-slash-commands
       --no-session-persistence --permission-mode dontAsk --effort low [--model …]
```

- Die Anfrage geht über stdin. Die Antwort kommt als strukturiertes JSON (`structured_output`).
- Werkzeuge, MCP-Server, Plugins/Hooks/CLAUDE.md und Sitzungsspeicher sind aus. Das Arbeitsverzeichnis ist ein leerer Temp-Ordner. Claude sieht also nur das, was TidyMac schickt.
- `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` u. ä. werden aus der Umgebung des Kindprozesses entfernt. Laut Anthropic würde Claude Code sonst stillschweigend über den API-Key abrechnen statt über das Abo. `--bare` wird bewusst nicht verwendet, weil es den Abo-Login ignoriert.
- „Status prüfen“ in den Einstellungen nutzt `claude auth status` und zeigt, ob du über claude.ai (und mit welchem Plan) angemeldet bist.

**Was aufs Nutzungskontingent geht:** Jeder Stapel (Standard: 20 Dateien) ist ein `claude -p`-Aufruf und zählt zu den Nutzungslimits deines Pro-Abos. Das sind das 5-Stunden-Limit und das Wochenlimit, geteilt mit claude.ai und Claude Code. Im Test kosteten 6 Dateien plus 1 Ordner (2 Aufrufe) zusammen etwa 5.100 Eingabe- und 600 Ausgabe-Tokens. Sparsam ist es, weil Regeln die eindeutigen Fälle ohne KI erledigen, Ergebnisse pro Datei (Inhalts-Hash + Änderungsdatum) gecacht werden, `--effort low` gesetzt ist und pro Lauf höchstens 300 Dateien an die KI gehen (einstellbar). Löschvorschläge und die tägliche Automatik nutzen dieselben Grenzen und denselben Cache. Im Hintergrund-Modus ist die KI standardmäßig aus, in der Automatik abschaltbar. Ist das Limit erreicht, bricht TidyMac die restlichen KI-Anfragen ab und nutzt nur die Regeln.

Einrichtung: Claude Code installieren (https://claude.com/claude-code), einmal im Terminal `claude` starten und mit dem Claude-Konto anmelden. TidyMac findet `claude` in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` usw. oder über den Pfad in den Einstellungen.

### Optional: Anthropic API-Key

In den Einstellungen umschaltbar. Direkter Aufruf der Messages API (`POST /v1/messages`, `anthropic-version: 2026-10-21`) mit strukturierter Ausgabe (`output_config.format`, JSON-Schema) und `effort: low`. Standardmodell ist `claude-opus-5-5`, wählbar sind auch `claude-sonnet-5-5` und `claude-haiku-5-5`. Für Opus/Sonnet ist der serverseitige Refusal-Fallback (`fallbacks: "default"`) aktiv. Die Abrechnung läuft pro Token über die Anthropic Console, unabhängig vom Abo. TidyMac zeigt eine Kostenschätzung pro Lauf.

### Datenschutz

- An die KI gehen nur: Dateiname, Pfad relativ zum Home (`~/Downloads/…`, kein Benutzername), Art, Größe, Datumsangaben, Herkunfts-Domain und – wenn eingeschaltet – höchstens ~2.000 Zeichen Textauszug (PDF, Text, Word/RTF/ODT, erste Excel-/PowerPoint-Inhalte). Nie ganze Dateien, nie Bilder.
- Ordner, Dateiendungen und Namensmuster, die nie an die KI gehen, sind einstellbar. Voreingestellt sind u. a. Passwort-Datenbanken, Schlüssel und Zertifikate (`kdbx`, `pem`, `key`, `p12`, `gpg`, `env`, …) sowie Namen wie `*passw*`, `*secret*`, `*geheim*`.
- Textauszüge werden im Prompt ausdrücklich als Daten markiert. Anweisungen darin befolgt Claude nicht.

## Zusatzfunktionen

- **Duplikate:** Größe → Teil-Hash (erste/letzte 64 KB) → vollständiger SHA-256, parallel. Hardlinks zählen nicht als Duplikat. Projekte werden ignoriert. Behalten wird das Exemplar im sinnvollsten Ordner mit dem besten Namen; per Klick änderbar. Die übrigen gehen nach Bestätigung in den Papierkorb.
- **Aufräum-Vorschläge:** große Dateien (≥ 500 MB), lange nicht geöffnete Dateien (Spotlight „zuletzt benutzt“, ≥ 365 Tage, ≥ 10 MB), alte Installer (≥ 30 Tage), leere Ordner, Reste (`.tmp`, `Thumbs.db`, alte Office-Sperrdateien), bereits entpackte Archive, abgebrochene Downloads. Pro Eintrag „Behalten“, „Papierkorb“ oder „Archivieren“ (geprüftes ZIP nach `~/Documents/Archiv/<Jahr-Monat>`, Original in den Papierkorb). Nichts davon passiert automatisch.
- **Löschen (Löschvorschläge)** in zwei Gruppen:
  - **Überflüssig**, unabhängig vom Alter und ohne KI: bereits entpackte Archive (bei ZIPs vergleicht TidyMac die Dateiliste des Archivs mit dem Ordner daneben; nur bei vollständiger Übereinstimmung 97 %), Installer (`.dmg`, `.pkg`) von Apps, die schon installiert sind, und sonst nach 7 Tagen, identische „(1)“-Kopien im selben Ordner, temporäre Reste, Torrent-Dateien und abgebrochene Downloads.
  - **Alt und vermutlich nicht mehr gebraucht:** Dateien, die in Downloads seit 3 Monaten, sonst seit einem Jahr (beides einstellbar) weder geöffnet (Spotlight „zuletzt benutzt“) noch geändert oder abgelegt wurden. Claude bewertet sie konsequent mit „löschen“, „behalten“ oder „unklar“, mit Begründung und Sicherheit. Ersetzbares und Erledigtes (Handbücher, alte Software, Bestätigungen, Tickets …) wird vorgeschlagen, Persönliches und rechtlich Wichtiges behalten. Vorgeschlagen wird „löschen“ ab 60 % (einstellbar).
  - Ausgenommen sind Projektordner, zusammengehörige Ordner (Fotoserien, Alben), geschützte Bereiche und bei der KI-Bewertung alles, was laut Datenschutz-Einstellungen nicht an die KI darf. **Nichts ist vorausgewählt und es gibt kein „Alle auswählen“:** Jede Datei bestätigst du einzeln, dann geht sie in den Papierkorb (rückgängig im Verlauf). „Behalten“ merkt sich die Datei, solange sie unverändert bleibt.
- **Automatik:** Einmal am Tag zur eingestellten Uhrzeit (Standard 10:00) werden die eingestellten Ordner (Standard: Downloads und Schreibtisch) gescannt und sortiert, mit Regeln und optional Claude. Automatisch ausgeführt werden nur Datei-Verschiebungen und -Umbenennungen ohne Warnung ab 90 % Konfidenz. Ordner verschieben, Papierkorb und Archivieren nie. Dateien, die sich in den letzten zwei Minuten geändert haben, bleiben bis zum nächsten Lauf liegen. Unsichere Vorschläge landen unter „Zur Prüfung“, Dateien ohne Vorschlag bleiben liegen. War der Mac zur Uhrzeit aus oder im Ruhezustand, holt TidyMac den Lauf am selben Tag nach; wer die Automatik nachmittags einschaltet, startet am nächsten Tag. Danach kommt eine Mitteilung mit „Rückgängig“-Knopf. TidyMac muss dafür laufen (am besten „Beim Anmelden starten“). Ein- und ausschalten unter Einstellungen › Automatik oder im Menüleisten-Symbol.
- **Hintergrund-Modus:** FSEvents beobachtet z. B. Downloads und Schreibtisch. Neue Dateien werden erst bearbeitet, wenn sie fertig sind: keine Download-Endung mehr, Größe und Datum stabil über die Wartezeit (Standard 60 s), nicht geöffnet. Automatisch einsortiert wird nur bei sicheren Regeln (≥ 90 %). Alles andere landet unter „Zur Prüfung“. Ordner werden nie automatisch bewegt. Danach kommt eine Mitteilung mit Zusammenfassung und „Rückgängig“-Knopf.

## tidyctl (Probeläufe auf der Kommandozeile)

```bash
cd TidyCore && swift build
```

```bash
.build/debug/tidyctl plan --home /pfad/zu/test/home --ai none --all
```

`scan`, `plan`, `dupes`, `cleanup` und `ai-status` sind reine Leseoperationen. `run` und `undo` sind nur mit `--home` auf einen Testordner erlaubt (der Papierkorb liegt dann ebenfalls im Testbereich). Für echte Dateien ist die App gedacht.

## Entwickler-Optionen (nur Debug-Builds)

`TIDYMAC_HOME`, `TIDYMAC_SUPPORT` und `TIDYMAC_SNAPSHOT_DIR` lassen die App gegen ein Test-Home laufen, mit eigenem Einstellungs-/Journal-Ordner. Die App macht dann einen automatischen Rundgang und speichert Fensteraufnahmen. So wurde die Oberfläche geprüft, ohne echte Dateien zu berühren.

## Bekannte Grenzen

- Verschieben über Volume-Grenzen hinweg wird nicht unterstützt (bewusst: Atomisches `renamex_np(RENAME_EXCL)` statt Kopieren+Löschen).
- „Gerade geöffnet“ erkennt Dateien, die ein Prozess offen hält. Apps, die Dateien nur kurz lesen (z. B. Vorschau), halten sie nicht offen.
- Ist „Schreibtisch & Dokumente“ in iCloud aktiv, werden Schreibtisch und Dokumente ohne Freigabe nicht selbst umsortiert. Als Ziel für Downloads ist „Dokumente“ aber erlaubt.
- Apps (`.app`) in Downloads, die nicht schon installiert sind, verschiebt TidyMac nicht; ziehe sie selbst nach „Programme“.
- Bilder werden von der KI nicht inhaltlich erkannt (nur Name/Metadaten).
- Die Bildschirm-Aufnahmen der Debug-Tour zeichnen die transparente Seitenleiste nicht mit; in der laufenden App ist sie normal sichtbar.

## Lizenz

[MIT](LICENSE) © 2026 Vincent Schmitt
