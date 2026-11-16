# Test-Evidenz

Belege für die Prüfung des Installers. Der Reboot-Test hängt seine Ausgabe
automatisch an diese Datei an. Rohdaten nicht beschönigen: Fehlschläge und
Umgebungsgrenzen bleiben dokumentiert.

## Status

| Prüfung | Umgebung | Status | Datum |
| --- | --- | --- | --- |
| `tests/static-checks.sh` | Entwicklungs-Workspace | **bestanden** | 2026-11-16 |
| `tests/local-smoke.sh` | Docker + Compose | offen – benötigt Docker-Daemon und ca. 5 GB freien Platz | – |
| `tests/reboot-test.sh` | Proxmox-VE-Host | offen – benötigt echten PVE-Host | – |

## Umgebungsgrenzen dieser Entwicklungsumgebung

- Kein Proxmox-VE-Host: `pct` und `pveversion` fehlen, LXC-Anlage und Reboot
  sind hier nicht ausführbar.
- Docker-CLI vorhanden, aber `/var/run/docker.sock` ist nicht zugänglich
  (`permission denied`); zusätzlich zu wenig freier Platz für zwei Image-Builds.
  Der lokale Compose-Smoke-Test konnte deshalb nicht laufen.
- Der Upstream-Build (Vite/TypeScript, Backend-Tests, Tesseract) und der
  Reboot-Nachweis müssen auf einem echten Proxmox-Host bzw. Docker-Host
  nachgeholt werden.

## Statische Prüfungen

Aufruf:

```bash
bash tests/static-checks.sh
```

Ergebnis vom 2026-11-16: alle Zeilen `[ OK ]`, Abschluss
`Alle statischen Prüfungen bestanden.`

Geprüft wurden 7 Skripte mit `bash -n`, ShellCheck ohne Warnungen, alle
systemd-/LXC-/Secrets-Merkmale, der README-Einzeiler, fehlende Platzhalter und
die Ausführbarkeit aller Skripte.

Geprüft werden unter anderem:

- `bash -n` für alle Installer-, Wrapper- und Testskripte
- `shellcheck -S warning`
- systemd: `Restart=always`, `network-online.target`, `multi-user.target`,
  Compose-Start
- LXC: `nesting=1,keyctl=1`, `onboot 1`, nächste freie CT-ID
- Secrets: `POSTGRES_PASSWORD`, `ENCRYPTION_KEY`
- README-Einzeiler und dokumentierte Deinstallation
- keine Platzhalter, alle Skripte ausführbar

## Lokaler Smoke-Test (Vorlage)

Auf einem Docker-Host mit ausreichend Platz:

```bash
bash tests/local-smoke.sh --port 18080
```

Nachweis, dass der Upstream-Build unverändert funktioniert:

```text
[TEST] Baue Images (kann 5–15 Minuten dauern)
[TEST] Starte Stack
[TEST] Warte auf Web-UI und Datenbank
[ OK ] Web-UI: http://127.0.0.1:18080
[ OK ] Healthcheck: ok
[TEST] Smoke-Test bestanden
```

## Reboot-Test (Vorlage)

Auf dem Proxmox-Host:

```bash
bash tests/reboot-test.sh --ctid <CT-ID>
```

Erwartete Nachweise in der Ausgabe:

- `onboot aktiv`
- `boot_id` vor und nach dem Reboot unterschiedlich
- `solooffice.service` nach dem Reboot `active`
- `GET /healthz` liefert `ok`
- Backend-Readiness `{"status":"ready"}` (oder gleichwertig)
- Container `solooffice-db`, `solooffice-backend`, `solooffice-frontend`
  laufen nach dem Reboot

## Offene Nachweise

- [x] Statische Prüfungen auf dem finalen Stand ausführen (2026-11-16,
      bestanden).
- [ ] `tests/local-smoke.sh` auf Docker-Host ausführen.
- [ ] `tests/reboot-test.sh` auf Proxmox VE 8.x ausführen.
- [ ] Upgrade von einer älteren Version mit bestehender Datenbank testen.
- [ ] Deinstallation mit und ohne `--purge` testen.
- [ ] DHCP-IP-Wechsel simulieren und Login erneut prüfen.
