#!/usr/bin/env bash
#
# reboot-test.sh - prüft Installation, rebootet den LXC und verifiziert,
# dass Dienst und Web-UI danach wieder erreichbar sind.
#
# Muss als root auf dem Proxmox-Host laufen.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTID=""
PORT=8080
PORT_EXPLICIT=0
OUT="${ROOT}/docs/test-evidence.md"
HOSTNAME_CT="solooffice"
TIMEOUT=240

usage() {
  cat <<EOF
Reboot-Test für SoloOffice

Usage: bash tests/reboot-test.sh [--ctid ID] [--port N] [--out FILE]

  --ctid ID    Container-ID (Default: Suche nach Hostname ${HOSTNAME_CT})
  --port N     Web-Port (Default: ${PORT})
  --out FILE   Evidenzdatei (Default: docs/test-evidence.md)
  --timeout N  Wartezeit in Sekunden (Default: ${TIMEOUT})
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; PORT_EXPLICIT=1; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unbekannte Option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

msg()  { printf '\033[1;34m[TEST]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || { fail "Bitte als root auf dem Proxmox-Host ausführen"; exit 1; }
command -v pct >/dev/null 2>&1 || { fail "pct fehlt - kein Proxmox-VE-Host?"; exit 1; }

if [[ -z "$CTID" ]]; then
  for id in $(pct list | awk 'NR > 1 {print $1}'); do
    host="$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; exit}')"
    if [[ "${host,,}" == "$HOSTNAME_CT" ]]; then
      CTID="$id"
      break
    fi
  done
fi
[[ -n "$CTID" ]] || { fail "Kein Container mit Hostname ${HOSTNAME_CT} gefunden (--ctid setzen)"; exit 1; }
pct config "$CTID" >/dev/null 2>&1 || { fail "CT ${CTID} existiert nicht"; exit 1; }

if [[ "$PORT_EXPLICIT" == "0" ]]; then
  CONFIGURED_PORT="$(pct exec "$CTID" -- sed -n 's/^APP_PORT=//p' /etc/solooffice/config.env 2>/dev/null | tail -n 1 || true)"
  CONFIGURED_PORT="${CONFIGURED_PORT%\"}"
  CONFIGURED_PORT="${CONFIGURED_PORT#\"}"
  CONFIGURED_PORT="${CONFIGURED_PORT%\'}"
  CONFIGURED_PORT="${CONFIGURED_PORT#\'}"
  if [[ "$CONFIGURED_PORT" =~ ^[0-9]+$ ]]; then
    PORT="$CONFIGURED_PORT"
  fi
fi

install -d -m 0755 "$(dirname "$OUT")"
exec > >(tee -a "$OUT") 2>&1

echo
echo "## Proxmox-Reboot-Test $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo
echo "- Host: \`$(hostname)\`"
echo "- CT: \`${CTID}\`"
echo "- Port: \`${PORT}\`"
echo "- PVE: \`$(pveversion 2>/dev/null || echo unbekannt)\`"
echo

HOSTNAME_ACTUAL="$(pct config "$CTID" | awk -F': ' '/^hostname:/{print $2}')"
VERSION="$(pct exec "$CTID" -- sed -n 's/^SOLOOFFICE_VERSION=//p' /etc/solooffice/version 2>/dev/null | tail -n 1 || true)"
IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo "- Hostname: \`${HOSTNAME_ACTUAL}\`"
echo "- Version: \`${VERSION:-unbekannt}\`"
echo "- IP: \`${IP:-unbekannt}\`"
echo

msg "Status vor dem Reboot"
pct config "$CTID" | grep -q '^onboot: 1' || fail "onboot ist nicht aktiv"
ok "onboot aktiv"
[[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]] || fail "CT ${CTID} läuft nicht"
ok "Container läuft"
pct exec "$CTID" -- systemctl is-active --quiet solooffice || fail "solooffice.service ist vor dem Reboot nicht aktiv"
ok "solooffice.service aktiv"
pct exec "$CTID" -- curl -fsS "http://127.0.0.1:${PORT}/healthz" || fail "Web-UI antwortet vor dem Reboot nicht"
echo
ok "Web-UI antwortet vor dem Reboot"
pct exec "$CTID" -- /usr/local/bin/solooffice-stack verify
BOOT_BEFORE="$(pct exec "$CTID" -- cat /proc/sys/kernel/random/boot_id)"
echo "- boot_id vorher: \`${BOOT_BEFORE}\`"
echo

msg "Container rebooten"
pct reboot "$CTID"
ok "Reboot ausgelöst"

BOOT_AFTER="$BOOT_BEFORE"
for _ in $(seq 1 "$TIMEOUT"); do
  CURRENT="$(pct exec "$CTID" -- cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  if [[ -n "$CURRENT" && "$CURRENT" != "$BOOT_BEFORE" ]]; then
    BOOT_AFTER="$CURRENT"
    break
  fi
  sleep 2
done
[[ "$BOOT_AFTER" != "$BOOT_BEFORE" ]] || fail "Container hat nicht neu gebootet"
ok "Neue boot_id: ${BOOT_AFTER}"
echo "- boot_id nachher: \`${BOOT_AFTER}\`"
echo

msg "Auf Dienst und Web-UI warten"
ready=0
for _ in $(seq 1 "$TIMEOUT"); do
  if pct exec "$CTID" -- systemctl is-active --quiet solooffice 2>/dev/null \
    && pct exec "$CTID" -- curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "$ready" != "1" ]]; then
  echo "--- CT-Status ---" >&2
  pct status "$CTID" || true
  echo "--- systemctl status solooffice ---" >&2
  pct exec "$CTID" -- systemctl status solooffice --no-pager -l || true
  echo "--- journalctl -u solooffice ---" >&2
  pct exec "$CTID" -- journalctl -u solooffice -n 200 --no-pager || true
  echo "--- docker compose ps ---" >&2
  pct exec "$CTID" -- bash -c 'cd /opt/solooffice && docker compose --env-file .env.solooffice -f docker-compose.yml ps -a' || true
  echo "--- docker compose logs ---" >&2
  pct exec "$CTID" -- bash -c 'cd /opt/solooffice && docker compose --env-file .env.solooffice -f docker-compose.yml logs --no-color --tail=200' || true
  fail "Web-UI antwortet nach dem Reboot nicht"
  exit 1
fi

pct exec "$CTID" -- /usr/local/bin/solooffice-stack verify
IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
ok "Dienst aktiv, Web-UI und Datenbank nach dem Reboot bereit"

echo
echo "### Healthcheck nach dem Reboot"
echo
echo '```text'
pct exec "$CTID" -- curl -fsS "http://127.0.0.1:${PORT}/healthz"
pct exec "$CTID" -- docker ps --filter 'name=solooffice-' --format '{{.Names}}\t{{.Status}}'
echo '```'
echo
echo "### Journal (letzte 20 Zeilen)"
echo
echo '```text'
pct exec "$CTID" -- journalctl -u solooffice -n 20 --no-pager
echo '```'
echo
echo "**Ergebnis: bestanden** — Web-UI nach Reboot erreichbar unter \`http://${IP:-<CT-IP>}:${PORT}\`."
echo

ok "Reboot-Test bestanden"
