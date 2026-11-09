# TidyMac installieren

Diese Anleitung ist für alle, die TidyMac einfach benutzen wollen, ohne selbst zu programmieren. Du brauchst etwa 5 Minuten, mit Claude-Anbindung etwa 10.

## Was du brauchst

- Einen **Mac mit Apple Silicon** (M1, M2, M3, M4 oder neuer). Intel-Macs werden nicht unterstützt.
- **macOS 15 (Sequoia) oder neuer**. Deine Version findest du unter  › Über diesen Mac.
- **Optional:** ein eigenes Claude-Konto mit Abo (Pro oder Max) auf [claude.ai](https://claude.ai) oder einen Anthropic-API-Key. Damit sortiert TidyMac auch Dateien, für die keine Regel passt. Ohne KI funktioniert TidyMac auch, dann nur mit den eingebauten und deinen eigenen Regeln.

## 1. TidyMac herunterladen

1. Öffne die Seite [Releases](https://github.com/Vyp3er/TidyMac/releases/latest).
2. Lade unter „Assets“ die Datei **`TidyMac-….zip`** herunter.
3. Öffne die ZIP-Datei im Ordner „Downloads“ mit einem Doppelklick. Daraus entsteht `TidyMac.app`.
4. Zieh **`TidyMac.app` in den Ordner „Programme“** (im Finder links in der Seitenleiste).

> Wichtig: Starte TidyMac aus dem Ordner „Programme“, nicht aus „Downloads“. Sonst räumt TidyMac sich beim Aufräumen der Downloads womöglich selbst weg, und die Berechtigungen passen nicht mehr.

<details>
<summary>Alternative: zusammen mit den anderen MacTweaks-Apps per Terminal</summary>

Der Sammel-Installer aus [MacTweaks](https://github.com/Vyp3er/MacTweaks) lädt TidyMac (und auf Wunsch KeyFlow, MacBuddy und NotchIsland) und legt es nach „Programme“:

```bash
curl -fsSL https://raw.githubusercontent.com/Vyp3er/MacTweaks/main/install.sh | bash -s -- TidyMac
```

Dann entfällt Schritt 2.
</details>

## 2. Den ersten Start erlauben

TidyMac ist ein privates Projekt und nicht bei Apple notarisiert. Deshalb blockiert macOS beim ersten Öffnen mit einer Meldung wie „TidyMac kann nicht geöffnet werden“ oder „Apple konnte nicht überprüfen …“. So erlaubst du den Start:

1. Doppelklicke `TidyMac.app` im Ordner „Programme“ und schließe die Meldung mit **„Fertig“** (nicht „In den Papierkorb legen“).
2. Öffne **Systemeinstellungen › Datenschutz & Sicherheit**.
3. Scrolle nach unten zu „Sicherheit“. Dort steht „TidyMac wurde blockiert …“. Klicke auf **„Dennoch öffnen“**.
4. Bestätige mit deinem Mac-Passwort oder Touch ID und klicke noch einmal auf **„Öffnen“**.

Das musst du nur einmal machen.

<details>
<summary>Alternative für das Terminal</summary>

Statt der Schritte 1–4 kannst du die Download-Markierung auch im Terminal entfernen und die App danach normal öffnen:

```bash
xattr -dr com.apple.quarantine /Applications/TidyMac.app
```
</details>

## 3. Festplattenvollzugriff erteilen

Beim ersten Start öffnet sich eine kurze Einführung. Auf Seite 2 geht es um den **Festplattenvollzugriff**. Den braucht TidyMac, um alle deine Ordner zu sehen und zuverlässig zu erkennen, was es *nicht* anfassen darf: Projektordner, Ordner im Dock und Finder-Favoriten.

1. Klicke auf **„Systemeinstellungen öffnen“**.
2. Schalte unter **Datenschutz & Sicherheit › Festplattenvollzugriff** den Schalter bei **TidyMac** ein. Steht TidyMac nicht in der Liste, füge `/Applications/TidyMac.app` mit „+“ hinzu.
3. Beende TidyMac (Menüleiste › Beenden) und starte es neu. In der Einführung steht dann „Freigegeben“.

Ohne diese Freigabe funktioniert TidyMac eingeschränkt: macOS fragt dann einzeln nach Schreibtisch, Dokumenten und Downloads, und der Schutz für Dock- und Finder-Favoriten greift nicht vollständig.

## 4. Optional: Claude als Sortierhilfe einrichten

Eindeutige Fälle (Screenshots, Rechnungen, Installer, Fotos …) erledigen Regeln ohne KI. Nur unklare Dateien schickt TidyMac an Claude, und zwar nur Dateiname, Pfad, Metadaten und höchstens etwa 2.000 Zeichen Textauszug, nie ganze Dateien.

**Weg A: mit deinem Claude-Abo (Pro oder Max).** TidyMac spricht über das offizielle Programm **Claude Code** von Anthropic mit Claude. Bei Claude Code meldest du dich selbst an. TidyMac sieht deine Zugangsdaten nie.

1. Öffne das **Terminal** (Programme › Dienstprogramme › Terminal).
2. Installiere Claude Code. Füge dazu diese Zeile ein und drücke Return:
   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```
3. Melde dich an:
   ```bash
   ~/.local/bin/claude auth login
   ```
   Es öffnet sich der Browser. Melde dich mit deinem Claude-Konto an und bestätige.
4. In TidyMac: **Einstellungen › KI**, „Claude Code CLI (Pro-Abo)“ wählen und auf **„Status prüfen“** klicken. Dort sollte stehen, dass du angemeldet bist.

Jeder Stapel von bis zu 20 unklaren Dateien ist eine Anfrage und zählt gegen das Nutzungslimit deines Abos (geteilt mit claude.ai). Ist das Limit erreicht, sortiert TidyMac nur noch mit Regeln weiter.

**Weg B: mit einem API-Key.** Unter **Einstellungen › KI** „Anthropic API-Key“ wählen und den Key aus der [Anthropic Console](https://console.anthropic.com) eintragen. Er wird nur im Schlüsselbund gespeichert. Abgerechnet wird pro Anfrage über dein Console-Konto; TidyMac zeigt nach jedem Lauf eine Kostenschätzung.

**Ohne KI:** „Aus (nur Regeln)“ wählen.

## 5. Der erste Aufräum-Lauf

Fang am besten klein an:

1. Links **„Aufräumen“** wählen, oben **„Ausgewählte Ordner“**, und nur deinen Ordner **Downloads** in der Liste lassen.
2. Auf **„Scannen & Vorschau“** klicken. Das liest nur, es wird noch nichts verändert.
3. Sieh dir die Vorschau an. Aus Downloads bekommt jede Datei einen Platz in **„Dokumente“**, in passenden Ordnern wie Finanzen, Uni, Wohnung oder Bilder. Fehlende Ordner legt TidyMac an. Installer und bereits entpackte Archive bleiben liegen, du findest sie unter „Löschen“. Jede geplante Aktion steht mit Ziel, Begründung und Sicherheit (in Prozent) da. Unsichere Vorschläge und solche mit Warnung sind schon abgewählt. Du kannst einzelne Aktionen ab- oder anwählen, das Ziel ändern oder einen anderen Namen eintragen. Über den Umschalter oben siehst du die Ordner vorher und nachher als Baum.
4. Klicke auf **„Ausführen“** und bestätige.
5. Gefällt dir etwas nicht: direkt im Banner auf **„Rückgängig“** klicken, oder später links unter **„Verlauf“** einen ganzen Lauf oder einzelne Aktionen zurücknehmen.

Was TidyMac nie tut: Dateien überschreiben (bei gleichem Namen heißt die neue Datei „Name 2.pdf“), endgültig löschen („Löschen“ heißt immer Papierkorb), in Projektordnern (Git, Xcode, Node, Python, LaTeX …) etwas verändern, `~/Library`, versteckte Dateien, Programme oder Cloud-Ordner anfassen. Was beim letzten Scan geschützt wurde und warum, steht links unter **„Geschützt“**.

## 6. Überflüssige und alte Dateien löschen

Links unter **„Löschen“** klickst du auf **„Dateien prüfen“**. TidyMac zeigt zwei Gruppen:

- **Überflüssig:** bereits entpackte Archive (das ZIP, wenn der Ordner daneben schon alles enthält), Installer bereits installierter Apps, identische „(1)“-Kopien, Reste und abgebrochene Downloads, egal wie alt.
- **Alt:** Dateien, die du lange weder geöffnet noch geändert hast (in Downloads seit 3 Monaten, sonst seit einem Jahr). Claude schätzt ein, ob du sie noch brauchst.

Projektordner, Fotoserien, Alben und geschützte Bereiche bleiben außen vor.

- Nichts ist vorausgewählt. Setze bei jeder Datei, die wirklich weg kann, das Häkchen **„Löschen“** und klicke dann oben auf **„… löschen“**.
- Gelöscht heißt immer: in den Papierkorb. Unter **„Verlauf“** kannst du es rückgängig machen.
- **„Behalten“** blendet die Datei aus, und TidyMac schlägt sie nicht mehr vor, solange sie unverändert bleibt.
- Ab wann eine Datei als alt gilt, wann Installer vorgeschlagen werden und wie sicher sich Claude sein muss, stellst du unter Einstellungen › Umbenennen & Löschen ein.

## 7. Optional: Automatik, Autostart und Hintergrund-Modus

- **Automatik:** Einstellungen › **Automatik** › „Jeden Tag automatisch aufräumen“. Dann räumt TidyMac jeden Tag um 10:00 (einstellbar) Downloads und Schreibtisch auf (andere Ordner kannst du hinzufügen). Automatisch passiert nur, was sicher ist; Unsicheres landet unter **„Zur Prüfung“**, gelöscht wird nie. War der Mac um 10:00 aus, holt TidyMac den Lauf am selben Tag nach. Mit „Jetzt ausführen“ probierst du es sofort aus. Danach kommt eine Mitteilung mit „Rückgängig“-Knopf. Damit das klappt, muss TidyMac laufen, also am besten auch den Autostart einschalten.
- **Autostart:** Einstellungen › Allgemein › **„Beim Anmelden starten“**. Eventuell will macOS das unter Systemeinstellungen › Allgemein › Anmeldeobjekte noch bestätigt haben.
- **Hintergrund-Modus:** Einstellungen › Hintergrund. TidyMac beobachtet dann z. B. Downloads und Schreibtisch und sortiert neue Dateien nur dann automatisch ein, wenn eine sichere Regel greift. Alles andere landet unter **„Zur Prüfung“**. Du bekommst eine Mitteilung mit „Rückgängig“-Knopf; die Mitteilungen erlaubst du beim Einschalten.

Das Symbol in der **Menüleiste** (Zauberstab) bietet Schnellaktionen wie „Downloads aufräumen …“, auch wenn das Fenster geschlossen ist.

## Probleme lösen

**„TidyMac ist beschädigt und kann nicht geöffnet werden“**
Die Download-Markierung ist noch gesetzt. Führe im Terminal den Befehl aus Schritt 2 („Alternative für das Terminal“) aus und öffne die App erneut.

**macOS fragt immer wieder nach Zugriff auf Schreibtisch, Dokumente oder Downloads**
Der Festplattenvollzugriff fehlt oder greift nicht mehr (zum Beispiel nach einem Update). Schalte ihn unter Datenschutz & Sicherheit › Festplattenvollzugriff einmal aus und wieder ein. Hilft das nicht, entferne TidyMac dort mit „–“, füge `/Applications/TidyMac.app` mit „+“ neu hinzu und starte TidyMac neu.

**„Claude Code nicht gefunden“ oder „nicht angemeldet“**
Wiederhole Schritt 4. Wenn du Claude Code woanders installiert hast, trag den Pfad unter Einstellungen › KI ein.

**„Nutzungslimit erreicht“**
Das Limit deines Claude-Abos ist aufgebraucht. TidyMac sortiert dann nur mit Regeln weiter. Warte, bis das Limit zurückgesetzt wird, oder sortiere bis dahin ohne KI.

**Eine Datei wurde nicht einsortiert**
Das ist Absicht, wenn TidyMac sich nicht sicher ist. Solche Dateien stehen in der Vorschau unten unter „Nicht zugeordnet“. Für wiederkehrende Fälle legst du unter Einstellungen › Regeln eine eigene Regel an, zum Beispiel „PDF mit ‚Rechnung‘ im Namen → ~/Documents/Finanzen/Rechnungen/{year}“.

## Update auf eine neue Version

Lade die neue ZIP herunter, beende TidyMac (Menüleiste › Beenden), ersetze `TidyMac.app` im Ordner „Programme“ und starte die App. Schritt 2 brauchst du eventuell noch einmal. Den Festplattenvollzugriff schaltest du einmal aus und wieder ein (siehe „macOS fragt immer wieder …“). Einstellungen, Regeln und der Verlauf zum Rückgängigmachen bleiben erhalten.

Mit dem [MacTweaks-Installer](https://github.com/Vyp3er/MacTweaks) geht das Update in einem Schritt; die alte Version landet dabei im Papierkorb.

## Deinstallieren

1. Schalte in TidyMac unter Einstellungen › Allgemein „Beim Anmelden starten“ aus.
2. Beende TidyMac (Menüleiste › Beenden) und lege `TidyMac.app` aus „Programme“ in den Papierkorb.
3. Optional die Daten löschen (Einstellungen, Regeln, Verlauf, KI-Cache). **Danach kannst du frühere Läufe nicht mehr rückgängig machen.**
   ```bash
   rm -rf ~/Library/Application\ Support/TidyMac
   ```
4. Falls du einen API-Key gespeichert hast: Öffne die Schlüsselbundverwaltung, suche nach `de.vincent-schmitt.TidyMac` und lösche den Eintrag.
5. Entferne TidyMac in den Systemeinstellungen unter Datenschutz & Sicherheit › Festplattenvollzugriff mit „–“.

Deine sortierten Dateien bleiben, wo sie jetzt sind. Claude Code bleibt installiert und lässt sich weiter nutzen.

## Datenschutz

- TidyMac arbeitet lokal. Ohne KI verlässt nichts deinen Mac.
- Mit KI gehen nur unklare Dateien an Claude, und davon nur: Dateiname, Pfad ab deinem Home-Ordner (`~/Downloads/…`, ohne Benutzernamen), Dateiart, Größe, Datumsangaben, Herkunfts-Domain und, wenn eingeschaltet, höchstens etwa 2.000 Zeichen Textauszug. Nie ganze Dateien, nie Bilder.
- Unter Einstellungen › KI legst du Ordner, Dateiendungen und Namensmuster fest, die nie an die KI gehen. Passwort-Datenbanken, Schlüssel, Zertifikate und Namen mit „Passwort“, „secret“ oder „geheim“ sind schon voreingestellt.
- Einstellungen, Verlauf und KI-Cache liegen nur auf deinem Mac in `~/Library/Application Support/TidyMac`.
