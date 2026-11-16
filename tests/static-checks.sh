#!/usr/bin/env bash
#
# static-checks.sh - schnelle Prüfungen ohne Proxmox und ohne Docker.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; fail=1; }

msg() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }

msg "Syntaxprüfung (bash -n)"
for f in install/*.sh scripts/* tests/*.sh; do
  [[ -f "$f" ]] || continue
  if bash -n "$f"; then
    ok "bash -n $f"
  else
    bad "bash -n $f"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  msg "ShellCheck (Warnungen)"
  if shellcheck -S warning install/*.sh scripts/* tests/*.sh; then
    ok "ShellCheck ohne Warnungen"
  else
    bad "ShellCheck hat Warnungen gemeldet"
  fi
else
  printf '\033[1;33m[WARN]\033[0m shellcheck fehlt, übersprungen\n'
fi

msg "Pflichtmerkmale"
grep -q '^Restart=always$' systemd/solooffice.service \
  && ok "systemd: Restart=always" || bad "systemd: Restart=always fehlt"
grep -q '^After=network-online.target' systemd/solooffice.service \
  && ok "systemd: After=network-online.target" || bad "systemd: network-online fehlt"
grep -q '^WantedBy=multi-user.target$' systemd/solooffice.service \
  && ok "systemd: WantedBy=multi-user.target" || bad "systemd: WantedBy fehlt"
grep -q '^ExecStart=/usr/local/bin/solooffice-stack up$' systemd/solooffice.service \
  && ok "systemd: Compose-Start" || bad "systemd: Compose-Start fehlt"

grep -q 'set -euo pipefail' install/solooffice.sh \
  && ok "Host-Installer: set -euo pipefail" || bad "Host-Installer: pipefail fehlt"
grep -q 'features nesting=1,keyctl=1' install/solooffice.sh \
  && ok "Host-Installer: LXC-Features" || bad "Host-Installer: LXC-Features fehlen"
grep -q 'onboot 1' install/solooffice.sh \
  && ok "Host-Installer: onboot" || bad "Host-Installer: onboot fehlt"
grep -q 'cluster/nextid' install/solooffice.sh \
  && ok "Host-Installer: nächste freie ID" || bad "Host-Installer: nextid fehlt"

grep -q 'ENCRYPTION_KEY' install/solooffice-inner.sh \
  && ok "Inner-Installer: Encryption-Key" || bad "Inner-Installer: Encryption-Key fehlt"
grep -q 'POSTGRES_PASSWORD' install/solooffice-inner.sh \
  && ok "Inner-Installer: Datenbank-Passwort" || bad "Inner-Installer: DB-Passwort fehlt"
grep -q 'systemctl enable solooffice' install/solooffice-inner.sh \
  && ok "Inner-Installer: systemd enable" || bad "Inner-Installer: systemd enable fehlt"

grep -q 'raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh' README.md \
  && ok "README: Einzeiler" || bad "README: Einzeiler fehlt"
grep -qi 'uninstall' README.md \
  && ok "README: Deinstallation dokumentiert" || bad "README: Deinstallation fehlt"

msg "Keine Platzhalter"
if grep -RInE 'TODO|FIXME|\[APP-NAME\]|\[USER\]|\[REPO\]' install scripts systemd README.md; then
  bad "Platzhalter oder TODO gefunden"
else
  ok "Keine Platzhalter"
fi

msg "Ausführbare Skripte"
for f in install/solooffice.sh install/solooffice-inner.sh scripts/solooffice-env scripts/solooffice-stack tests/*.sh; do
  if [[ -x "$f" ]]; then
    ok "ausführbar: $f"
  else
    bad "nicht ausführbar: $f"
  fi
done

if [[ "$fail" == "0" ]]; then
  printf '\n\033[1;32mAlle statischen Prüfungen bestanden.\033[0m\n'
else
  printf '\n\033[1;31mStatische Prüfungen fehlgeschlagen.\033[0m\n' >&2
  exit 1
fi
