# Arbeitszeiterfassung

## Neues Supabase-Projekt einrichten

1. Im **SQL Editor** des neuen Projekts den gesamten Inhalt von
   [setup-new-project.sql](supabase/setup-new-project.sql) in einer neuen Abfrage
   ausführen. Die Datei führt alle Migrationen in einer Transaktion aus und ist
   für ein leeres Projekt bestimmt. Alternativ alle Migrationen per CLI
   einspielen. Für die Erstinstallation genügt einer dieser Wege.
2. Unter **Authentication** die öffentliche Registrierung deaktivieren. Unter
   **Users → Add user → Create new user** das erste Admin-Konto mit einer
   erreichbaren E-Mail-Adresse und einem Passwort anlegen. Die Benutzer-ID
   kopieren und im SQL Editor folgenden Befehl ausführen. Den Platzhalter
   `ADMIN-UUID` durch die kopierte ID und `Mein Name` durch den Anzeigenamen
   ersetzen.

   ```sql
   insert into public.profiles (id, full_name, role)
   values ('ADMIN-UUID', 'Mein Name', 'admin');
   ```

3. Die Edge-Funktion [manage-employee](supabase/functions/manage-employee/index.ts)
   im neuen Projekt bereitstellen. Dafür unter **Edge Functions → Deploy a new
   function → Via Editor** den Funktionscode in `index.ts` einfügen und den
   Funktionsnamen `manage-employee` setzen. In den Funktionseinstellungen
   **Verify JWT with legacy secret** deaktivieren. Die Funktion prüft die
   Anmeldung und die Admin-Rolle selbst.
4. In der Windows-App als Admin anmelden und die Mitarbeiterkonten unter
   **Verwaltung → Mitarbeiter verwalten** mit Geschäftsadresse und
   Startpasswort anlegen.

### Windows-Version 0.9.3

Für bestehende AZE-Projekte im Supabase-Dashboard **Edge Functions →
manage-employee → Code** öffnen, `index.ts` durch den
[aktuellen Funktionscode](supabase/functions/manage-employee/index.ts)
ersetzen und **Deploy updates** wählen. Danach die
[Windows-Appdateien](downloads/AZE-Windows-Appdateien.zip) aktualisieren.

- Beim Anlegen die Geschäftsadresse prüfen und ein Startpasswort mit mindestens
  zwölf Zeichen setzen. Das Startpasswort persönlich weitergeben. Mitarbeitende
  melden sich mit ihrer Geschäftsadresse an und ändern es über **Passwort ändern**.
- Im Mitarbeiterprofil lässt sich unter **Passwort zurücksetzen** ein neues
  Startpasswort setzen. Das funktioniert auch für ein bereits angelegtes,
  aktives Mitarbeiterprofil aus einer früheren Einladung.
- Wenn der Admin sein eigenes Passwort vergisst, kann der Projektinhaber über
  die Supabase Auth Admin API ein neues Passwort für dieselbe Benutzer-ID
  setzen. Die Benutzer-ID verbindet das Auth-Konto mit den vorhandenen Buchungen.
- Der Ablauf benötigt keinen SMTP-Dienst.

### Tägliche Supabase-Backups und Erreichbarkeit

Im GitHub-Repository laufen zwei Actions. Das Backup startet täglich um
02:17 UTC. Die separate Prüfung um 13:43 UTC ruft eine kleine Datenbankfunktion
über die Supabase-API auf. Beide lassen sich im Reiter **Actions** manuell
mit **Run workflow** auslösen. Zeitpläne können verspätet starten oder
ausfallen. Die Prüfung garantiert keine durchgehende Verfügbarkeit von
Supabase Free.

1. Im schon eingerichteten Projekt die
   [Healthcheck-Migration](supabase/migrations/20261123010000_aze_healthcheck.sql)
   einmal im SQL Editor ausführen. Ein neues Projekt erhält die Funktion
   über das Erstinstallationsskript.
2. Unter **GitHub → Settings → Secrets and variables → Actions → Secrets**
   `SUPABASE_PUBLISHABLE_KEY` mit dem öffentlichen Supabase-Schlüssel anlegen.
   Für `SUPABASE_BACKUP_DB_URL` in Supabase **Connect → Session pooler → URI**
   wählen und die URI mit dem Platzhalter `[YOUR-PASSWORD]` kopieren. Das
   Datenbankpasswort als eigenes Secret `SUPABASE_BACKUP_DB_PASSWORD` unverändert
   eintragen. Die URI beginnt mit `postgresql://` und endet ohne Query-Parameter.
   Lade unter **Supabase → Database → Settings →
   SSL Configuration** das Zertifikat herunter. Kopiere den vollständigen
   PEM-Text unter **Variables** in `SUPABASE_BACKUP_CA_CERT`. Der Workflow
   prüft damit die Verschlüsselung und den Hostnamen der Verbindung.
3. Am eigenen Rechner mit [age](https://github.com/FiloSottile/age/releases)
   ein Schlüsselpaar erzeugen. Unter Windows lässt sich age per `winget install
   --id FiloSottile.age -e` installieren. In einem neu geöffneten Terminal
   `age-keygen -o aze-backup-key.txt` ausführen. Unter **Variables** nur den
   öffentlichen Wert `age1…` als `SUPABASE_BACKUP_AGE_RECIPIENT` anlegen.
   `aze-backup-key.txt` sicher außerhalb von GitHub aufbewahren. Ohne diese
   Datei lassen sich die Backups nicht wiederherstellen.
4. In **Actions** beide Workflows einmal manuell starten. Eine erfolgreiche
   Sicherung enthält unter **Artifacts** die verschlüsselte Datei
   `aze.dump.age`. GitHub behält sie 30 Tage. Bei einem öffentlichen Repo
   können GitHub-Zeitpläne nach 60 Tagen ohne Repo-Aktivität deaktiviert werden.

Das Backup enthält die App-Daten der Schemas `public` und `private` und
die Auth-Konten und Identitäten. Das Datenbankschema und der Edge-Funktionscode
stehen versioniert im Repository. Supabase-Projekteinstellungen, aktive
Anmeldesitzungen und Projekt-Secrets gehören nicht zum Backup.

Zur Wiederherstellung eine separate, leere Supabase-Datenbank mit dem Schema
aus dem Commit des Backup-Laufs vorbereiten. `age -d -i aze-backup-key.txt
-o aze.dump aze.dump.age` erzeugt das PostgreSQL-Archiv. `pg_restore -l aze.dump`
zeigt den Inhalt. Die Daten mit `pg_restore --file=aze-data.sql aze.dump`
in SQL umwandeln. Im leeren Ziel die Daten in einer Transaktion mit
`session_replication_role = replica` laden. Vor dem Import in derselben
Transaktion die bei der Ersteinrichtung erzeugte Zeile `company_settings`
mit ID 1 entfernen. Für das Wiederherstellen der Auth-Tabellen und das
Setzen von `session_replication_role` sind die Datenbankrechte des
Projektinhabers erforderlich. Die Wiederherstellung zuerst am Testziel
prüfen und anschließend die entschlüsselten Dateien sicher ablegen oder löschen.

### Start der Stundenberechnung am 24.11.2026

Für ein bereits eingerichtetes AZE-Projekt die
[Stichtag-Migration](supabase/migrations/20261123000000_time_tracking_start.sql)
einmal im SQL Editor ausführen und die Monatsberichte aktualisieren. Die
Tagesübersicht, der laufende Monatssaldo und neue Abschlüsse rechnen ab
dem 24.11.2026. Die Änderung gilt für das gesamte Team. Vorhandene Buchungen
und gespeicherte Monatsabschlüsse bleiben erhalten. Das Erstinstallationsskript
enthält den Stichtag bereits.

### Windows-Version 0.9.2

Über **Auf diesem Gerät angemeldet bleiben** speichert die Windows-App
die Sitzung für dieses Windows-Benutzerkonto verschlüsselt. **Abmelden**
entfernt die gespeicherte Sitzung.

Unter **Verwaltung → Mitarbeiter verwalten** kannst du die Abteilung
**Geschäftsführung** zuweisen. Für diese Konten blendet die App Saldo,
Vortrag und Differenzen in den Ansichten und Exporten aus. Die erfassten
Zeiten und die gespeicherten Monatsabschlüsse bleiben erhalten.

## Lokal entwickeln

Voraussetzung ist Node.js 22 oder neuer. Im vorhandenen Checkout ausführen.

```sh
npm ci
npm test
npm run build
npm run dev
```

Für die Anmeldung `.env.example` als `.env.local` kopieren und die Projekt-URL sowie den Publishable Key aus den API-Einstellungen eintragen. Für lokale Supabase-Projekte kann der öffentliche Anon-Key als Ersatz für den Publishable Key dienen. In der Codex-Cloud mit dem konfigurierten HTTPS-Proxy den Entwicklungsserver mit `NODE_USE_ENV_PROXY=1 npm run dev` starten.

Unter `/login` mit dem angelegten Supabase-Konto anmelden. Die Übersicht erfordert ein aktives Profil. Der Bereich `/admin` erfordert die Rolle `admin`.

## Datenbank

Mit Supabase CLI und Docker lässt sich die Migration über `supabase start` lokal anwenden. Für ein gehostetes Projekt die Migration über eine verknüpfte Supabase CLI mit `supabase db push` anwenden. Im gehosteten Projekt die öffentliche Registrierung in den Auth-Einstellungen deaktivieren. Das erste Auth-Konto über die Supabase-Administration anlegen und seine UUID in `public.profiles` mit Rolle `admin` eintragen. Weitere Profile werden in späteren Meilensteinen über die Admin-Verwaltung eingerichtet.

Mitarbeitende können abgeschlossene Zeitbuchungen über begründete Korrekturanträge korrigieren. Monatsabschlüsse sind abgeleitete Auswertungen. Mitarbeitende lesen nur ihre eigenen Summen und ändern die zugrunde liegenden Buchungen bis zur Sperre. Der Teamkalender liefert fremde genehmigte Abwesenheiten ohne Notizen und blendet fremde Krankmeldungen aus.

Die Zeitlogik verwendet Berliner Kalendertage und reale verstrichene Minuten. Die Monatsberechnung verteilt die Wochenarbeitszeit gleichmäßig auf Montag bis Freitag und behandelt genehmigtes Sonstiges als bezahlt. Ein Zeitausgleichstag behält sein Tagessoll und belastet den Saldo damit einmal. Feiertage sind in diesem ersten Meilenstein nur über bezahlte Abwesenheiten abbildbar.

## Kostenloser Browser-Test auf Render

In Render unter **New → Blueprint** das GitHub-Repository verbinden. Die Datei
`render.yaml` legt einen Node.js-Webdienst im Tarif **Free** in Frankfurt an.
Beim Import die zwei Werte aus `.env.local` in die gleichnamigen
Umgebungsvariablen eintragen. Die URL und der Publishable Key sind in den
Supabase-API-Einstellungen zu finden. Der Blueprint benötigt keine weitere
Datenbank und kein Datenbankpasswort.

Nach dem Deployment die von Render angezeigte Adresse öffnen. Der Start leitet
zur Anmeldung weiter. Nach Inaktivität kann der erste Aufruf etwas dauern.

## Windows-App mit Supabase Free

Die Windows-App läuft auf Windows x64. Das bisherige Startpaket mit
`Arbeitszeiterfassung-starten.cmd` wurde nach einer Defender-Meldung aus
dem aktuellen Downloadbereich entfernt. Eine Prüfung durch Microsoft steht aus.

1. Die [offizielle Electron-Laufzeit für Windows x64](https://github.com/electron/electron/releases/download/v45.4.1/electron-v45.4.1-win32-x64.zip)
   in einen neuen Ordner entpacken.
2. Die [AZE-Appdateien](downloads/AZE-Windows-Appdateien.zip) in denselben
   Ordner entpacken. `app.asar` muss anschließend direkt im Unterordner
   `resources` liegen.
3. Den entpackten Ordner mit Windows Defender prüfen. Wenn der Virenschutz
   keine Bedrohung meldet, `electron.exe` per Doppelklick öffnen und mit dem
   Supabase-Konto für dieses Projekt anmelden. Für Supabase ist eine
   Internetverbindung erforderlich.

Zum erneuten Packen mit Node.js 24, `.env.local` und dem öffentlichen
Supabase Publishable Key:

```sh
npm ci
npm run desktop:package
```

Das Ergebnis liegt in `.desktop/release/Arbeitszeiterfassung-win32-x64`.
Das Paket ist unsigniert. Für ein bestehendes Supabase-Projekt die unten
aufgeführten Schritte zur Aktivierung ausführen. Die Übersicht ordnet
Buchungen nach ihrem Berliner Startdatum zu und nutzt abgeschlossene
Vormonate für den Saldoübertrag.

## Windows-Version 0.3.0 aktivieren und testen

Die folgenden Versionsabschnitte dokumentieren die Änderungen seit 0.3.0.
Für die aktuelle Windows-Installation gelten die Schritte oben.

1. Im vorhandenen Supabase-Projekt unter **SQL Editor → New query** genau die
   [neue Migration](supabase/migrations/20261120020000_calendar_admin_reports.sql)
   vollständig ausführen. Bei Erstinstallation alle Migrationen in ihrer
   Dateireihenfolge anwenden.
2. Für **Mitarbeiterkonto anlegen** die Edge-Funktion `manage-employee`
   im selben Supabase-Projekt bereitstellen. In **Edge Functions →
   Deploy a new function → Via Editor** den vollständigen
   [Funktionscode](supabase/functions/manage-employee/index.ts) als
   `index.ts` einfügen und als `manage-employee` bereitstellen. In den
   Einstellungen der Funktion **Verify JWT with legacy secret** deaktivieren.
   Die Funktion verifiziert die Anmeldung selbst über Supabase Auth und prüft
   zusätzlich aktiven Adminstatus. Supabase stellt der Funktion die benötigten
   Backend-Variablen bereit.
   Mit verknüpfter Supabase CLI geht es über
   `supabase functions deploy manage-employee --no-verify-jwt`.
3. Die App nach der aktuellen Windows-Anleitung oben öffnen.

Die Admin-Konsole legt Mitarbeiterkonten mit Startpasswort an. Das Passwort
persönlich weitergeben und vom Mitarbeiter in der App ändern lassen.

### Fachlicher Testablauf mit Testdaten

1. Als Admin anmelden, ein fiktives Mitarbeiterkonto anlegen und bei Bedarf
   dessen Wochenstunden und Jahresurlaub speichern.
2. Als Mitarbeiter ein- und ausstempeln, optional Pause und Notiz eintragen.
   Eine Buchung nachtragen oder korrigieren und den Status „Zur Prüfung“
   kontrollieren.
3. Im Mitarbeiterkonto Urlaub, Krankheit, Zeitausgleich und Sonstiges
   beantragen. Monats- und Jahresansicht und die vier Filter prüfen.
4. Als Admin die Anträge prüfen und genehmigen oder ablehnen. Bei einer
   vergessenen Ausstempelzeit eine Endzeit mit Begründung erfassen.
   Den Kalender nochmals als Mitarbeiter öffnen und prüfen, dass eigene
   Krankmeldungen sichtbar sind und fremde ausgeblendet werden.
5. Für einen vergangenen Monat erst offene Vorgänge abschließen, dann in
   **Monatsberichte** den Monatsabschluss bestätigen. Den Saldo im Folgemonat
   als Vortrag prüfen. Eine nachträgliche Änderung im gesperrten Monat
   als Mitarbeiter versuchen.
6. Je einen laufenden und einen abgeschlossenen Bericht als CSV exportieren
   und die Druckansicht ansehen.

Ein Abschluss ist ab dem ersten Tag des Folgemonats möglich. Nach dem ersten
Abschluss folgen weitere Monate in chronologischer Reihenfolge, damit der
Übertrag vollständig bleibt. Zeit über Mitternacht gehört zum Berliner
Startdatum. Ganztägige Abwesenheiten zählen auf Montag bis Freitag.

## Windows-Version 0.4.0

Arbeitszeiten lassen sich nach ISO-Kalenderwoche oder Monat auswählen.
Unter **Abwesenheit beantragen** können Mitarbeitende Anträge einreichen
und deren Status überprüfen. Admins können dort zusätzlich direkt
genehmigte Abwesenheiten eintragen.

Im Supabase SQL Editor die neue
[Pausen-Migration](supabase/migrations/20261120030000_live_breaks.sql)
einmal vollständig ausführen. Danach lässt sich eine Pause per Klick
starten und beenden. Gestempelte Pausen ergeben beim Ausstempeln den
Pausenabzug in vollen Minuten. Bei einer Buchung ohne gestempelte Pause
gilt weiterhin die automatische Mittagspause. Eine ausdrücklich
eingegebene Pausendauer hat Vorrang.

Zum App-Update das laufende Fenster schließen, das Windows-Startpaket
im vorhandenen App-Ordner entpacken und die Dateien ersetzen.

## Windows-Version 0.5.0

1. Im bestehenden Supabase-Projekt
   [die neue SQL-Migration](supabase/migrations/20261120040000_team_and_daily_reports.sql)
   einmal vollständig ausführen. Der bisherige SQL-Tab kann wiederverwendet
   werden.
2. Für die Abteilung bei neuen Konten den Code der vorhandenen Edge-Funktion
   [manage-employee](supabase/functions/manage-employee/index.ts) durch die
   aktuelle Version ersetzen und erneut bereitstellen.
3. Die App schließen und das aktualisierte Windows-Startpaket im vorhandenen
   App-Ordner entpacken. Anschließend `Arbeitszeiterfassung-starten.cmd` öffnen.

Unter **Verwaltung → Mitarbeiter verwalten** Teamgruppen anlegen und den
Mitarbeitern eine Abteilung und bei Bedarf mehrere Teamgruppen zuordnen.
Im **Teamkalender** lassen sich die Abwesenheiten nach Teamgruppe filtern.
Die **Admin-Auswertung** im Kalender zeigt die Kennzahlen eines Mitarbeiters
für den ausgewählten Monat.

Bei **Arbeitszeiten** steht pro Tag der Zeitraum vom ersten Beginn bis zum
letzten Ende. Die Nettozeit ergibt sich aus den einzelnen erfassten
Arbeitsabschnitten abzüglich ihrer Pausen. Einzelbuchungen sind über
**Buchungsdetails** erreichbar.

In **Monatsberichte** einen Mitarbeiter und Monat auswählen, um alle
Kalendertage mit Ist, Soll und Differenz zu sehen. Bundesweit einheitliche
deutsche Feiertage werden angezeigt, haben null Sollzeit und verbrauchen
keinen Urlaubstag. Regionale Feiertage sind bisher nicht enthalten.
Neu abgeschlossene Monate speichern die Tageswerte. Bei älteren Abschlüssen
kennzeichnet die App rekonstruierte Tageswerte. Die alte Monatssumme gilt
weiterhin.

## Windows-Version 0.6.0

1. Im vorhandenen Supabase-Projekt die
   [Dashboard-Migration](supabase/migrations/20261120050000_dashboard_and_current_reports.sql)
   einmal vollständig im SQL Editor ausführen. Der vorhandene SQL-Tab genügt.
2. Für **Passwort zurücksetzen** die bestehende Edge-Funktion
   [manage-employee](supabase/functions/manage-employee/index.ts) mit der
   neuen `index.ts` aktualisieren und erneut bereitstellen.
3. Die App schließen, die neue Windows-ZIP im vorhandenen Ordner entpacken
   und `Arbeitszeiterfassung-starten.cmd` starten.

Laufende Monatsberichte, Kalender-Kennzahlen und CSV berücksichtigen die
Berliner Kalendertage bis einschließlich heute. Abgeschlossene Monate
zeigen weiterhin die archivierten Werte. Im Teamkalender erscheinen
genehmigte Abwesenheiten. Eigene Anträge und Entscheidungen bleiben auf
dem Dashboard und in den jeweiligen Antragsansichten sichtbar.

Bei vergessenem Mitarbeiterpasswort öffnet ein Admin **Verwaltung →
Mitarbeiter verwalten**, klappt das Profil auf und wählt **Passwort
zurücksetzen**. Das neue Startpasswort persönlich weitergeben. Die
Mitarbeiterin oder der Mitarbeiter kann es nach dem Anmelden über
**Passwort ändern** ersetzen.

## Windows-Version 0.7.0

Für dieses Update genügt das Windows-Startpaket. Vor dem Entpacken
die App beenden. Falls sie bereits als Punkt im Windows-Infobereich
läuft, dort per Rechtsklick **Beenden** wählen. Danach im vorhandenen
App-Ordner entpacken und den Starter wieder öffnen.

- Der Teamstatus zeigt eine Stempeluhr-Karte pro aktivem Mitarbeiter
  mit Start, Ende und einem Timer während der Arbeit oder Pause.
- Ausgeschiedene Mitarbeitende über **Aktiv** deaktivieren und speichern.
  Ihre Profile stehen dann unten unter **Inaktive Mitarbeitende**.
  Historische Buchungen und Berichte bleiben erhalten.
- Abwesenheitsanträge, Nachträge und Korrekturen öffnen sich als Dialog.
- **Monatsnachweis als PDF** ist in der Monatsansicht der eigenen
  Arbeitszeiten und in der Admin-Ansicht für einen ausgewählten
  Mitarbeiter verfügbar. Der Nachweis hat Platz für beide Unterschriften.
- In Windows erscheint bei laufender App ein Punkt im Infobereich.
  Grün bedeutet eingestempelt, Gelb Pause, Grau ausgestempelt.
  Das Rechtsklickmenü steuert Stempeln und Pausen.
  Beim Schließen des Fensters bleibt die angemeldete App im Hintergrund.
  **Beenden** im Rechtsklickmenü schließt sie vollständig.

## Windows-Version 0.8.0

1. Im bestehenden Supabase-Projekt die
   [SQL-Migration für Pausenzeiten und Einstellungen](supabase/migrations/20261120060000_departments_and_break_history.sql)
   vollständig im SQL Editor ausführen.
2. Die vorhandene Edge-Funktion
   [manage-employee](supabase/functions/manage-employee/index.ts) mit der
   neuen `index.ts` aktualisieren und erneut bereitstellen.
3. Die laufende App vollständig beenden, bei Bedarf über das Symbol im
   Windows-Infobereich. Das neue Startpaket im vorhandenen Ordner entpacken
   und den Starter öffnen.

Der Teamkalender filtert nach Abteilung. Die Administration kann unter
**Arbeitszeiten** einen Mitarbeiter auswählen, dessen Zeiten und
gestempelte Pausen ansehen und bei ausgewähltem Monat den Monatsnachweis
speichern. Die Auswahl gewährt Lesezugriff auf fremde Arbeitszeiten.
Die automatische Mittagspause lässt sich in **Mitarbeiter verwalten**
pro Konto ein- oder ausschalten. Gestempelte Pausen und eingetragene
Pausenminuten können weiterhin erfasst werden. Beginn und Ende einer
Pause sind für neu gestempelte Pausen verfügbar. Bereits abgeschlossene
Pausen ohne Zeitstempel zeigen weiterhin ihre erfasste Dauer.

## Windows-Version 0.9.1

Das Dashboard zeigt den persönlichen Resturlaub.
Die **Mitarbeiterauswertung** hat einen eigenen
Menüpunkt für Admins mit Mitarbeiter- und Monatsauswahl sowie dem
Resturlaub für das gewählte Jahr.

Das Originalfoto `Background.png` und das Logo `Logo.png` sind im
App-Paket enthalten und werden automatisch angezeigt. Bei Bedarf kann
die App alternative Bilddateien aus dem Ordner von `electron.exe` laden.
Die Endung muss zum Dateiformat
passen (`.jpg`, `.jpeg` oder `.png`, jeweils bis 12 MB).

- `nextway-container.jpg` erscheint beim Login und im App-Kopf.
- `nextway-logo-dark.png` ist das schwarze Logo und wird auch im Monatsnachweis verwendet.
- `nextway-logo-light.png` ist optional und wird bevorzugt in der dunklen Seitenleiste verwendet.

Danach die App über **Beenden** im Windows-Infobereich vollständig schließen
und neu starten.
