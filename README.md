# SoloOffice für Proxmox VE

Ein Einzeiler installiert auf einem Proxmox-VE-Host einen unprivilegierten
Debian-12-LXC mit Docker und [SoloOffice](https://github.com/TingelTangelBob/SoloOffice):
Rechnungen, Kunden, Aufträge, Belege, EÜR und lokale OCR – vollständig lokal,
ohne Cloud-Dienst.

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh)"
```

Alternativ mit `curl`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh)"
```

Nicht interaktiv (z. B. aus einem anderen Skript):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh)" -- --yes
```

## Was der Installer macht

```text
Proxmox-Host
└─ solooffice.sh
   ├─ wählt die nächste freie CT-ID
   ├─ erstellt LXC "solooffice" (Debian 12, unprivileged, nesting/keyctl/fuse)
   ├─ setzt onboot: 1 und installiert Docker CE + Compose
   ├─ klont TingelTangelBob/SoloOffice nach /opt/solooffice
   ├─ erzeugt DB-Passwort und ENCRYPTION_KEY (einmalig)
   ├─ baut die Images und startet solooffice.service
   └─ prüft Dienst, Web-UI und Datenbank

LXC "solooffice"
├─ solooffice.service        docker compose up, Restart=always
├─ /opt/solooffice           Upstream-Code + generierte .env-Dateien
├─ /etc/solooffice           config.env + secrets.env (0600)
├─ solooffice_postgres_data  PostgreSQL-Volume
└─ solooffice_backups_data   Backup-Volume der Anwendung
```

Der Lauf dauert inklusive Node-/Vite-Build etwa 5–15 Minuten. Am Ende steht
sinngemäß:

```text
[INFO] SoloOffice Installer
[ OK ] Nächste freie CT-ID: 123
[ OK ] Container 123 erstellt
[INFO] Starte Installation im Container (kann 5–15 Minuten dauern)
...
[ OK ] Dienst aktiv, Web-UI und Datenbank bereit

  ╭────────────────────────────────────────────────────────────╮
  │  ✓  SoloOffice ist installiert und bereit                  │
  ╰────────────────────────────────────────────────────────────╯

  Web-UI        http://192.168.1.50:8080
  Container     CT 123  ·  solooffice  ·  onboot aktiv
  Version       v0.9.14b-11-g63e2de1

  Erster Login
    Web-UI öffnen und den ersten Benutzer registrieren.
    Dieser Benutzer erhält Administratorrechte.

  Schnellzugriff
    Logs       pct exec 123 -- journalctl -u solooffice -f
    Status     pct exec 123 -- solooffice-stack status
    Secrets    pct exec 123 -- cat /etc/solooffice/secrets.env
    Update     bash -c "$(wget -qLO - .../install/solooffice.sh)" -- --ctid 123 --update
    Entfernen  bash -c "$(wget -qLO - .../install/solooffice.sh)" -- --ctid 123 --uninstall
```

Die Web-UI ist danach unter `http://<CT-IP>:8080` erreichbar. Der erste
registrierte Benutzer wird Administrator; danach ist die offene Registrierung
standardmäßig geschlossen.

`CORS_ORIGIN` und `APP_BASE_URL` werden beim Start automatisch auf
`http://<CT-IP>:<Port>` gesetzt. Rufe die UI deshalb über genau diese Adresse
auf. Für Hostname, anderen Port oder HTTPS trage `PUBLIC_ORIGIN` in
`/etc/solooffice/config.env` ein, sonst schlägt der Login wegen der
Origin-Prüfung fehl.

## Voraussetzungen

- Proxmox VE 8.x, Root-Zugriff auf den Host
- Internetzugang für Template, Debian-Pakete, Docker Hub, npm und GitHub
- mindestens 16 GB freier Storage und 4 GB freier RAM auf dem Host
- `wget` oder `curl` auf dem Host (im Einzeiler enthalten)

## Standardwerte

| Einstellung | Standard | Änderbar mit |
| --- | --- | --- |
| Container-ID | nächste freie ID | `--ctid ID` |
| Hostname | `solooffice` | `--hostname NAME` |
| vCPU | 2 | `--cores N` |
| RAM | 4096 MiB | `--ram MB` (Minimum 2048) |
| Disk | 16 GiB | `--disk GB` (Minimum 8) |
| Web-Port | 8080 | `--port PORT` |
| Bridge | `vmbr0` | `--bridge NAME` |
| Storage | automatisch (rootdir) | `--storage NAME` |
| Upstream-Ref | `main` | `--ref REF` |

> 8 GB Disk und 2 GB RAM sind für den Node-/Vite-Build, PostgreSQL und
> Tesseract zu knapp. Der Installer verweigert weniger als 2 GB RAM und 8 GB
> Disk; 16 GB Disk sind empfohlen.

Alle Optionen:

```text
--ctid --hostname --cores --ram --disk --storage --template-storage
--bridge --port --repo --ref --update --uninstall --purge --force --yes --debug
```

## Erster Login

1. `http://<CT-IP>:8080` öffnen.
2. Erstes Konto registrieren – es erhält die Administratorrolle.
3. Workspace und Firmendaten in der Anwendung einrichten.
4. Weitere Benutzer per Einladung hinzufügen.

Es gibt **kein vorgegebenes Admin-Passwort**. SMTP ist nicht vorkonfiguriert;
Einladungen, Passwort-Zurücksetzung und E-Mail-Versand benötigen eigene
SMTP-Daten in `/etc/solooffice/config.env`.

## Update

Vor dem Update ein Backup erstellen:

```bash
pct exec <CT-ID> -- solooffice-stack backup
```

Dann den Installer mit `--update` erneut ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh)" -- --ctid <CT-ID> --update
```

Der Update-Modus behält Secrets, Konfiguration und Datenbank-Volume. Er holt
den gewählten Git-Ref, baut die Images neu, startet den Dienst neu und prüft
Web-UI sowie Datenbank. Ein bei der Installation gesetzter Port bleibt
erhalten, solange beim Update kein `--port` angegeben wird.

Port nachträglich ändern:

```bash
pct exec <CT-ID> -- sed -i 's/^APP_PORT=.*/APP_PORT=9090/' /etc/solooffice/config.env
pct exec <CT-ID> -- systemctl restart solooffice
pct exec <CT-ID> -- ufw allow 9090/tcp   # nur falls ufw aktiv ist
``` Datenbankmigrationen laufen beim Backend-Start
automatisch. Schlägt der Build fehl, läuft die alte Version weiter.

Ohne `--update` erkennt der Installer einen vorhandenen Container mit
Hostname `solooffice` und wechselt nach Rückfrage ebenfalls in den
Update-Modus.

## Deinstallation

Dienst und Container entfernen, **Daten behalten**:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh)" -- --ctid <CT-ID> --uninstall
```

Zusätzlich Datenbank-Volume, Code und Konfiguration löschen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh)" -- --ctid <CT-ID> --uninstall --purge
```

Der LXC selbst bleibt in beiden Fällen bestehen. Komplett entfernen:

```bash
pct stop <CT-ID> && pct destroy <CT-ID> --purge
```

## Betrieb, Logs und Diagnose

```bash
pct enter <CT-ID>
systemctl status solooffice
journalctl -u solooffice -f
solooffice-stack status
solooffice-stack verify
solooffice-stack logs 200
```

Wichtige Dateien im Container:

| Pfad | Inhalt |
| --- | --- |
| `/etc/solooffice/config.env` | Port, Origin, SMTP, OCR, Registrierung |
| `/etc/solooffice/secrets.env` | `POSTGRES_PASSWORD`, `ENCRYPTION_KEY` (0600) |
| `/etc/solooffice/version` | installierter Git-Stand |
| `/opt/solooffice/.env.solooffice` | generierte Compose-Umgebung (0600) |
| `/opt/solooffice/.env.backend.solooffice` | generierte Backend-Umgebung (0600) |
| `/var/log/solooffice-install.log` | Installationsprotokoll |

Nach Änderungen an `config.env`:

```bash
systemctl restart solooffice
```

`AUTO_ORIGIN=1` setzt `CORS_ORIGIN` und `APP_BASE_URL` bei jedem Start auf
`http://<aktuelle-CT-IP>:<Port>`. Das hält den Login auch nach einem
DHCP-Adresswechsel funktionsfähig.

## Backup und Wiederherstellung

```bash
pct exec <CT-ID> -- solooffice-stack backup
```

Das nutzt das Upstream-Skript `manage-instances.sh` und legt SQL-Dump sowie
Kopien der Env-Dateien unter `/opt/solooffice/backups/` ab. Zusätzlich gibt es
Workspace-Backups (JSON/ZIP) in der Weboberfläche. Beide Orte liegen im LXC und
sind **kein** Offsite-Backup: regelmäßig auf ein zweites System kopieren und
eine Wiederherstellung testen. Bewahre `ENCRYPTION_KEY` zusammen mit dem
Dump auf – ohne ihn sind gespeicherte SMTP-Passwörter unlesbar.

## HTTPS und öffentlicher Zugriff

Der Installer liefert bewusst nur HTTP im lokalen Netz. Für öffentlichen
Zugriff einen Reverse-Proxy mit TLS vor den Container setzen und in
`/etc/solooffice/config.env` eintragen:

```dotenv
APP_PORT=8080
PUBLIC_ORIGIN=https://office.example.de
TRUST_PROXY=2
```

`TRUST_PROXY=2` gilt für Host-Proxy **und** internes Frontend-nginx. Ohne
vorgeschalteten Proxy bleibt `1` richtig. `COOKIE_SECURE` wird bei einer
`https://`-Origin automatisch aktiviert. Danach:

```bash
systemctl restart solooffice
```

Nur Port 80/443 des Proxys öffentlich freigeben; Port 8080 bleibt im lokalen
Netz.

## Fehlersuche

Bei einem Fehler gibt der Installer die **komplette Kette** aus: Aufrufstack,
Container-Status und -Konfiguration, Installationslog, `systemctl status`,
`journalctl` für Dienst und Docker, `docker compose ps/logs`, Ports, Speicher
und die letzten Host-Logzeilen. Nichts wird auf die letzte Zeile gekürzt.

Für einen vollständigen Shell-Trace:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh)" -- --ctid <CT-ID> --debug
```

Im Container:

```bash
pct enter <CT-ID>
bash /root/solooffice-inner.sh --debug --port 8080
# Update-Modus:
bash /root/solooffice-inner.sh --debug --update
```

Häufige Ursachen:

| Symptom | Prüfen |
| --- | --- |
| Docker startet nicht | LXC braucht `features: nesting=1,keyctl=1,fuse=1`; `journalctl -u docker` |
| Build bricht ab | freier Platz (`df -h`), RAM (`free -m`), `docker compose logs` |
| Web-UI 502 | Backend/Datenbank: `solooffice-stack status`, `solooffice-stack logs` |
| Login schlägt fehl | `CORS_ORIGIN`/`PUBLIC_ORIGIN` muss exakt der Browser-URL entsprechen |
| Keine E-Mails | SMTP in `/etc/solooffice/config.env` fehlt |

## Tests

```bash
# ohne Proxmox/Docker: Syntax, ShellCheck, Pflichtmerkmale
bash tests/static-checks.sh

# lokaler Docker-Build inkl. Web-UI und Datenbank
bash tests/local-smoke.sh

# auf dem Proxmox-Host: Reboot + boot_id + Web-UI, schreibt docs/test-evidence.md
bash tests/reboot-test.sh --ctid <CT-ID>
```

Der Reboot-Test belegt mit `boot_id` vor/nach, `systemctl is-active`, dem
HTTP-Check auf `/healthz` und dem Backend-Readiness-Check, dass die Instanz
nach einem Neustart wieder erreichbar ist.

## Grenzen

- SoloOffice ist laut Upstream ein Beta-/Testrelease (v0.9.x), kein
  freigegebenes Produkt für unbeaufsichtigten Steuerbetrieb.
- Keine ELSTER-Übertragung; E-Rechnungen sollten zusätzlich mit den
  offiziellen KOSIT-/FeRD-Werkzeugen geprüft werden.
- OCR-Ergebnisse sind Vorschläge und müssen vor der Übernahme geprüft werden.
- Ohne SMTP kein E-Mail-Versand, keine Einladungen und kein Passwort-Reset.
- Der Installer richtet keinen TLS-Proxy, kein Offsite-Backup und keine
  Überwachung ein.

## Lizenz

Der Installer und die Wrapper stehen unter der MIT-Lizenz (siehe `LICENSE`).
SoloOffice selbst steht unter AGPL-3.0; es wird unverändert aus dem
Upstream-Repository bezogen.
