#!/usr/bin/env bash
#
# solooffice.sh - Proxmox VE Installer für SoloOffice
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main/install/solooffice.sh)"
#
# Erstellt einen unprivilegierten Debian-12-LXC mit Docker, installiert
# SoloOffice aus dem Upstream-Repository und richtet einen reboot-sicheren
# systemd-Dienst ein.
#
set -euo pipefail
umask 077

APP="SoloOffice"
APP_ID="solooffice"
APP_PORT=8080
CTID=""
CTID_EXPLICIT=0
PORT_EXPLICIT=0
CT_HOSTNAME="solooffice"
CORES=2
RAM_MB=4096
SWAP_MB=512
DISK_GB=16
STORAGE=""
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"
REPO_URL="https://github.com/TingelTangelBob/SoloOffice"
REPO_REF="main"
DEPLOY_RAW="https://raw.githubusercontent.com/HatchetMan111/SoloOffice-Proxmox/main"
FORCE=0
ASSUME_YES=0
DEBUG=0
UPDATE_ONLY=0
DO_UPDATE=0
UNINSTALL=0
PURGE=0
HOST_LOG="/var/log/solooffice-install.log"
TMP_DIR=""
EXISTING_HOST=""

msg_info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
msg_ok()    { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
msg_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
msg_error() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }
die()       { msg_error "$*"; exit 1; }

usage() {
  cat <<EOF
${APP} - Proxmox VE Installer

Usage: bash solooffice.sh [OPTIONEN]

  --ctid ID                Container-ID (Default: nächste freie)
  --hostname NAME          Hostname (Default: ${CT_HOSTNAME})
  --cores N                vCPUs (Default: ${CORES})
  --ram MB                 RAM in MiB (Default: ${RAM_MB})
  --disk GB                Rootdisk in GiB (Default: ${DISK_GB})
  --storage NAME           Rootfs-Storage (Default: automatisch)
  --template-storage NAME  Template-Storage (Default: ${TEMPLATE_STORAGE})
  --bridge NAME            Netzwerk-Bridge (Default: ${BRIDGE})
  --port PORT              Web-Port (Default: ${APP_PORT})
  --repo URL               Upstream-Repository (Default: ${REPO_URL})
  --ref REF                Upstream-Git-Ref (Default: ${REPO_REF})
  --update                 Bestehenden Container aktualisieren
  --uninstall              Dienst und Container entfernen, Daten behalten
  --purge                  Mit --uninstall: Datenbank-Volume und Dateien löschen
  --force                  Nur mit --ctid: fremden Container ersetzen
  --yes                    Keine Rückfragen
  --debug                  bash -x mit Zeitstempeln
  --help                   Diese Hilfe
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="${2:?--ctid benötigt einen Wert}"; CTID_EXPLICIT=1; shift 2 ;;
    --hostname) CT_HOSTNAME="${2:?--hostname benötigt einen Wert}"; shift 2 ;;
    --cores) CORES="${2:?--cores benötigt einen Wert}"; shift 2 ;;
    --ram) RAM_MB="${2:?--ram benötigt einen Wert}"; shift 2 ;;
    --disk) DISK_GB="${2:?--disk benötigt einen Wert}"; shift 2 ;;
    --storage) STORAGE="${2:?--storage benötigt einen Wert}"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="${2:?--template-storage benötigt einen Wert}"; shift 2 ;;
    --bridge) BRIDGE="${2:?--bridge benötigt einen Wert}"; shift 2 ;;
    --port) APP_PORT="${2:?--port benötigt einen Wert}"; PORT_EXPLICIT=1; shift 2 ;;
    --repo) REPO_URL="${2:?--repo benötigt einen Wert}"; shift 2 ;;
    --ref) REPO_REF="${2:?--ref benötigt einen Wert}"; shift 2 ;;
    --update) DO_UPDATE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unbekannte Option: $1" ;;
  esac
done

[[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )) \
  || die "Ungültiger Port: ${APP_PORT}"
[[ "$CORES" =~ ^[0-9]+$ ]] && (( CORES >= 1 && CORES <= 64 )) \
  || die "Ungültige vCPU-Anzahl: ${CORES}"
[[ "$RAM_MB" =~ ^[0-9]+$ ]] && (( RAM_MB >= 2048 && RAM_MB <= 262144 )) \
  || die "Ungültiger RAM: ${RAM_MB} (Minimum 2048 MiB)"
[[ "$DISK_GB" =~ ^[0-9]+$ ]] && (( DISK_GB >= 8 && DISK_GB <= 1024 )) \
  || die "Ungültige Disk-Größe: ${DISK_GB} (Minimum 8 GiB)"
[[ "$CT_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || die "Ungültiger Hostname: ${CT_HOSTNAME} (nur a-z, 0-9, -)"
[[ "$REPO_REF" =~ ^[^[:space:]]+$ ]] || die "Ungültiger Git-Ref: ${REPO_REF}"
[[ -z "$CTID" || "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige CT-ID: ${CTID}"
[[ "$SWAP_MB" =~ ^[0-9]+$ ]] && (( SWAP_MB >= 0 && SWAP_MB <= 262144 )) \
  || die "Ungültiger Swap: ${SWAP_MB}"
[[ "$PURGE" == "0" || "$UNINSTALL" == "1" ]] || die "--purge ist nur mit --uninstall erlaubt"
[[ "$FORCE" == "0" || "$CTID_EXPLICIT" == "1" ]] || die "--force ist nur mit --ctid erlaubt"
[[ "$(id -u)" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen"

install -d -m 0755 "$(dirname "$HOST_LOG")"
touch "$HOST_LOG"
chmod 600 "$HOST_LOG"
if [[ "$DEBUG" == "1" ]]; then
  export PS4='+ $(date +%H:%M:%S) ${BASH_SOURCE##*/}:${LINENO}: '
  exec > >(tee -a "$HOST_LOG") 2>&1
  set -x
else
  exec > >(tee -a "$HOST_LOG") 2>&1
fi

ctid_in_use() {
  pct config "$1" >/dev/null 2>&1 || qm config "$1" >/dev/null 2>&1
}

ctid_hostname() {
  pct config "$1" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; exit}'
}

next_free_id() {
  local id tries=0
  id="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"[:space:]')" || true
  [[ "$id" =~ ^[0-9]+$ ]] || die "Konnte nächste freie Container-ID nicht ermitteln"
  while ctid_in_use "$id"; do
    id=$((id + 1))
    tries=$((tries + 1))
    (( tries < 1000 )) || die "Keine freie Container-ID gefunden"
  done
  printf '%s' "$id"
}

find_ct_by_hostname() {
  local id host
  for id in $(pct list 2>/dev/null | awk 'NR > 1 {print $1}'); do
    host="$(ctid_hostname "$id")"
    if [[ "${host,,}" == "${CT_HOSTNAME,,}" ]]; then
      printf '%s' "$id"
      return 0
    fi
  done
  return 1
}

resolve_dns() {
  local ns
  local -a list=()
  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    case " ${list[*]:-} " in *" $ns "*) continue ;; esac
    list+=("$ns")
  done < <(awk '/^[[:space:]]*nameserver[[:space:]]+/{print $2}' /etc/resolv.conf 2>/dev/null | grep -vE '^(127\.|::1$|fe80:)' || true)
  list+=(1.1.1.1 9.9.9.9)
  printf '%s' "$(IFS=','; echo "${list[*]}")"
}

resolve_storage() {
  if [[ -n "$STORAGE" ]]; then
    pvesm status -content rootdir | awk -v s="$STORAGE" 'NR > 1 && $1 == s {found=1} END {exit !found}' \
      || die "Storage ${STORAGE} hat keinen rootdir-Inhalt"
  else
    STORAGE="$(pvesm status -content rootdir | awk 'NR > 1 && $3 == "active" {print $1; exit}')"
    [[ -n "$STORAGE" ]] || die "Kein aktiver Storage mit rootdir gefunden (--storage setzen)"
  fi
}

select_template() {
  pvesm status -content vztmpl | awk -v s="$TEMPLATE_STORAGE" 'NR > 1 && $1 == s {found=1} END {exit !found}' \
    || die "Template-Storage ${TEMPLATE_STORAGE} hat keinen vztmpl-Inhalt"
  msg_info "Aktualisiere Template-Liste"
  pveam update >/dev/null 2>&1 || msg_warn "pveam update fehlgeschlagen, nutze vorhandene Liste"
  local template
  template="$(pveam available --section system | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^debian-12-standard_/) {print $i; exit}}')"
  [[ -n "$template" ]] || die "Kein debian-12-standard-Template verfügbar"
  if ! pveam list "$TEMPLATE_STORAGE" | grep -Fq "$template"; then
    msg_info "Lade Template ${template}"
    pveam download "$TEMPLATE_STORAGE" "$template" >/dev/null
  fi
  TEMPLATE_PATH="$(pveam list "$TEMPLATE_STORAGE" | awk -v t="$template" 'index($0, t) {print $1; exit}')"
  [[ -n "$TEMPLATE_PATH" ]] || TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${template}"
  msg_ok "Template: ${TEMPLATE_PATH}"
}

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  [[ -t 0 ]] || return 0
  local answer
  read -r -p "$1 [j/N] " answer || return 1
  [[ "$answer" =~ ^[jJyY]$ ]]
}

cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

on_error() {
  local code="$1" line="$2" cmd="$3" i
  trap - ERR
  set +e
  {
    echo
    msg_error "Abbruch (Exit ${code}) in Zeile ${line}: ${cmd}"
    echo "--- Aufrufstack ---"
    for ((i = 0; i < ${#FUNCNAME[@]}; i++)); do
      printf '  %s (%s:%s)\n' "${FUNCNAME[$i]}" "${BASH_SOURCE[$i]:-?}" "${BASH_LINENO[$i]:-?}"
    done
    if [[ -n "${CTID:-}" ]] && pct config "$CTID" >/dev/null 2>&1; then
      echo "--- Container-Status ---"
      pct status "$CTID" 2>&1 || true
      echo "--- Container-Konfiguration ---"
      pct config "$CTID" 2>&1 | head -n 60 || true
      if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
        echo "--- Install-Log im Container (letzte 160 Zeilen) ---"
        pct exec "$CTID" -- tail -n 160 /var/log/solooffice-install.log 2>&1 || true
        echo "--- systemctl status solooffice ---"
        pct exec "$CTID" -- systemctl status solooffice --no-pager -l 2>&1 || true
        echo "--- journalctl -u solooffice ---"
        pct exec "$CTID" -- journalctl -u solooffice -n 160 --no-pager 2>&1 || true
        echo "--- journalctl -u docker ---"
        pct exec "$CTID" -- journalctl -u docker -n 80 --no-pager 2>&1 || true
        echo "--- docker compose ps ---"
        pct exec "$CTID" -- bash -c 'cd /opt/solooffice 2>/dev/null && docker compose --env-file .env.solooffice -f docker-compose.yml ps -a' 2>&1 || true
        echo "--- docker compose logs ---"
        pct exec "$CTID" -- bash -c 'cd /opt/solooffice 2>/dev/null && docker compose --env-file .env.solooffice -f docker-compose.yml logs --no-color --tail=200' 2>&1 || true
        echo "--- Ports und Speicher im Container ---"
        pct exec "$CTID" -- ss -tlnp 2>&1 || true
        pct exec "$CTID" -- df -h / /var/lib/docker 2>&1 || true
        pct exec "$CTID" -- free -m 2>&1 || true
      fi
    elif [[ -n "${EXISTING_HOST:-}" ]]; then
      echo "--- Container ${CTID} ---"
      echo "Gehört zu '${EXISTING_HOST}', nicht zu ${APP}. Er wurde nicht verändert."
    fi
    echo "--- Host-Log ${HOST_LOG} (letzte 120 Zeilen) ---"
    tail -n 120 "$HOST_LOG" 2>/dev/null || true
    echo
    echo "Nächster Schritt:"
    if [[ -n "${CTID:-}" ]] && pct config "$CTID" >/dev/null 2>&1; then
      echo "  pct enter ${CTID}"
      echo "  bash /root/solooffice-inner.sh --debug --port ${APP_PORT}$([[ "${UPDATE_ONLY:-0}" == "1" ]] && echo ' --update')"
      echo "oder Installer erneut mit --debug starten:"
      echo "  bash -c \"\$(wget -qLO - ${DEPLOY_RAW}/install/solooffice.sh)\" -- --ctid ${CTID} --debug"
    else
      echo "  Installer mit einer freien ID erneut starten, z. B. --ctid <ID>"
    fi
  } >&2
  exit "$code"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

fetch_asset() {
  local rel="$1" dest="$2"
  if [[ -n "${ROOT_DIR:-}" && -f "${ROOT_DIR}/${rel}" ]]; then
    cp "${ROOT_DIR}/${rel}" "$dest"
  else
    msg_info "Lade ${rel}"
    curl -fsSL "${DEPLOY_RAW}/${rel}" -o "$dest" \
      || die "Download fehlgeschlagen: ${DEPLOY_RAW}/${rel}"
  fi
}

wait_for_ct_network() {
  msg_info "Warte auf Netzwerk und DNS im Container"
  local ready=0
  for _ in $(seq 1 60); do
    if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != "1" ]]; then
    pct exec "$CTID" -- ip -4 addr 2>&1 || true
    pct exec "$CTID" -- cat /etc/resolv.conf 2>&1 || true
    die "Container hat kein funktionierendes DNS"
  fi
  msg_ok "Container hat Netzwerk und DNS"
}

create_container() {
  resolve_storage
  select_template
  msg_info "Erstelle Container ${CTID} (${CT_HOSTNAME})"
  local output
  for _ in 1 2 3 4 5; do
    if output="$(pct create "$CTID" "$TEMPLATE_PATH" \
      --hostname "$CT_HOSTNAME" \
      --cores "$CORES" \
      --memory "$RAM_MB" \
      --swap "$SWAP_MB" \
      --rootfs "${STORAGE}:${DISK_GB}" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
      --unprivileged 1 \
      --features nesting=1,keyctl=1,fuse=1 \
      --onboot 1 \
      --ostype debian \
      --nameserver "$CT_DNS" \
      --description "${APP} - Rechnungen, Kunden und EÜR" \
      --tags "$APP_ID" 2>&1)"; then
      msg_ok "Container ${CTID} erstellt"
      return 0
    fi
    if [[ "$output" == *"already exists"* && "$CTID_EXPLICIT" == "0" ]]; then
      msg_warn "ID ${CTID} wurde parallel belegt, wähle nächste freie ID"
      CTID="$(next_free_id)"
      continue
    fi
    printf '%s\n' "$output" >&2
    die "pct create ist fehlgeschlagen"
  done
  die "Keine freie Container-ID nach 5 Versuchen"
}

start_container() {
  if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
    msg_info "Starte Container ${CTID}"
    pct start "$CTID"
  fi
  for _ in $(seq 1 60); do
    [[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]] && return 0
    sleep 1
  done
  die "Container ${CTID} startet nicht"
}

wait_for_ct_ready() {
  msg_info "Warte auf systemd im Container"
  local state
  for _ in $(seq 1 60); do
    state="$(pct exec "$CTID" -- systemctl is-system-running 2>/dev/null || true)"
    case "$state" in
      running|degraded) return 0 ;;
    esac
    sleep 2
  done
  msg_warn "systemd meldet keinen vollständig bereiten Zustand; fahre fort"
  return 0
}

ensure_onboot() {
  if pct config "$CTID" | grep -q '^onboot: 1'; then
    msg_ok "onboot ist aktiv"
  else
    pct set "$CTID" --onboot 1
    msg_ok "onboot aktiviert"
  fi
}

run_inner() {
  msg_info "Übertrage Installer-Dateien in den Container"
  pct push "$CTID" "${TMP_DIR}/solooffice-inner.sh" /root/solooffice-inner.sh --perms 700
  pct push "$CTID" "${TMP_DIR}/solooffice.service" /root/solooffice.service --perms 644
  pct push "$CTID" "${TMP_DIR}/solooffice-env" /root/solooffice-env --perms 755
  pct push "$CTID" "${TMP_DIR}/solooffice-stack" /root/solooffice-stack --perms 755

  local -a args=(
    --port "$APP_PORT"
    --repo "$REPO_URL"
    --ref "$REPO_REF"
    --dns "$CT_DNS"
    --unit-file /root/solooffice.service
    --env-script /root/solooffice-env
    --stack-script /root/solooffice-stack
  )
  [[ "$UPDATE_ONLY" == "1" ]] && args+=(--update)
  [[ "$UPDATE_ONLY" == "1" && "$PORT_EXPLICIT" == "1" ]] && args+=(--set-port)
  [[ "$DEBUG" == "1" ]] && args+=(--debug)

  msg_info "Starte Installation im Container (kann 5–15 Minuten dauern)"
  pct exec "$CTID" -- bash /root/solooffice-inner.sh ${args[@]+"${args[@]}"}
}

adopt_installed_port() {
  local port
  port="$(pct exec "$CTID" -- sed -n 's/^APP_PORT=//p' /etc/solooffice/config.env 2>/dev/null | tail -n 1 || true)"
  port="${port%\"}"
  port="${port#\"}"
  port="${port%\'}"
  port="${port#\'}"
  if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
    APP_PORT="$port"
  fi
}

verify_from_host() {
  msg_info "Verifiziere Dienst und Web-UI vom Host aus"
  local ok=0
  for _ in $(seq 1 90); do
    if pct exec "$CTID" -- systemctl is-active --quiet solooffice 2>/dev/null \
      && pct exec "$CTID" -- curl -fsS "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  [[ "$ok" == "1" ]] || die "Dienst oder Web-UI antwortet im Container nicht"
  pct exec "$CTID" -- /usr/local/bin/solooffice-stack verify
  msg_ok "Dienst aktiv, Web-UI und Datenbank bereit"
}

print_summary() {
  local ip version
  ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  version="$(pct exec "$CTID" -- sed -n 's/^SOLOOFFICE_VERSION=//p' /etc/solooffice/version 2>/dev/null | tail -n 1)"
  cat <<EOF

  ${APP} ist installiert.

  Web-UI:       http://${ip:-<CT-IP>}:${APP_PORT}
  Container:    CT ${CTID} (${CT_HOSTNAME}), onboot aktiv
  Version:      ${version:-unbekannt}
  Erster Login: ersten Benutzer registrieren (wird Administrator).
  Secrets:      /etc/solooffice/secrets.env im Container (Modus 600)
  Logs:         pct exec ${CTID} -- journalctl -u solooffice -f
  Status:       pct exec ${CTID} -- solooffice-stack status
  Update:       bash -c "\$(wget -qLO - ${DEPLOY_RAW}/install/solooffice.sh)" -- --ctid ${CTID} --update
  Deinstall:    bash -c "\$(wget -qLO - ${DEPLOY_RAW}/install/solooffice.sh)" -- --ctid ${CTID} --uninstall

  Hinweis: HTTP ist nur für das lokale Netz gedacht. Für öffentlichen Zugriff
  einen Reverse-Proxy mit TLS davor setzen und PUBLIC_ORIGIN in
  /etc/solooffice/config.env eintragen.

EOF
}

uninstall_ct() {
  msg_info "Deinstalliere ${APP} aus CT ${CTID}"
  start_container
  wait_for_ct_ready

  if [[ "$PURGE" == "1" ]]; then
    msg_warn "PURGE löscht das PostgreSQL-Volume, /opt/solooffice und /etc/solooffice unwiderruflich."
    confirm "Wirklich alle SoloOffice-Daten löschen?" || die "Abgebrochen"
  else
    confirm "SoloOffice-Dienst und Container entfernen (Daten bleiben)?" || die "Abgebrochen"
  fi

  pct exec "$CTID" -- systemctl disable --now solooffice 2>/dev/null || true
  pct exec "$CTID" -- bash -c 'cd /opt/solooffice 2>/dev/null && docker compose --env-file .env.solooffice -f docker-compose.yml down --remove-orphans' 2>/dev/null || true
  if [[ "$PURGE" == "1" ]]; then
    pct exec "$CTID" -- bash -c 'cd /opt/solooffice 2>/dev/null && docker compose --env-file .env.solooffice -f docker-compose.yml down -v --remove-orphans' 2>/dev/null || true
    pct exec "$CTID" -- rm -rf /opt/solooffice /etc/solooffice /var/lib/solooffice
  fi
  pct exec "$CTID" -- rm -f /etc/systemd/system/solooffice.service /usr/local/bin/solooffice-env /usr/local/bin/solooffice-stack
  pct exec "$CTID" -- systemctl daemon-reload || true
  pct exec "$CTID" -- rm -f /root/solooffice-inner.sh /root/solooffice.service /root/solooffice-env /root/solooffice-stack

  msg_ok "SoloOffice entfernt"
  cat <<EOF

  Der Container CT ${CTID} (${CT_HOSTNAME}) bleibt bestehen.
  Komplett entfernen (unwiderruflich):  pct stop ${CTID} && pct destroy ${CTID} --purge

EOF
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen"
  [[ -d /etc/pve ]] || die "/etc/pve fehlt: ist das ein Proxmox-VE-Host?"
  local bin
  for bin in pct pveam pvesh pvesm openssl curl; do
    command -v "$bin" >/dev/null 2>&1 || die "Benötigtes Werkzeug fehlt: ${bin}"
  done
  [[ -d "/sys/class/net/${BRIDGE}" ]] || die "Bridge ${BRIDGE} existiert nicht"
  [[ "$(df -Pk /var/lib 2>/dev/null | awk 'NR==2{print $4}')" -gt 1048576 ]] 2>/dev/null \
    || msg_warn "Wenig freier Platz auf dem Host; Docker-Build und Images brauchen mehrere GB"

  msg_info "${APP} Installer"
  CT_DNS="$(resolve_dns)"
  msg_info "DNS für den Container: ${CT_DNS}"

  if [[ "$UNINSTALL" == "1" ]]; then
    if [[ -z "$CTID" ]]; then
      CTID="$(find_ct_by_hostname)" || die "Kein Container mit Hostname '${CT_HOSTNAME}' gefunden"
    fi
    pct config "$CTID" >/dev/null 2>&1 || die "CT ${CTID} existiert nicht"
    EXISTING_HOST="$(ctid_hostname "$CTID")"
    [[ "${EXISTING_HOST,,}" == "${CT_HOSTNAME,,}" ]] \
      || die "CT ${CTID} gehört zu '${EXISTING_HOST}', nicht zu ${APP}"
    uninstall_ct
    return 0
  fi

  if [[ "$DO_UPDATE" == "1" ]]; then
    [[ -n "$CTID" ]] || CTID="$(find_ct_by_hostname)" || die "Kein Container mit Hostname '${CT_HOSTNAME}' gefunden"
    pct config "$CTID" >/dev/null 2>&1 || die "CT ${CTID} existiert nicht"
    EXISTING_HOST="$(ctid_hostname "$CTID")"
    [[ "${EXISTING_HOST,,}" == "${CT_HOSTNAME,,}" ]] \
      || die "CT ${CTID} gehört zu '${EXISTING_HOST}', nicht zu ${APP}"
    UPDATE_ONLY=1
  elif [[ "$CTID_EXPLICIT" == "1" ]]; then
    [[ "$CTID" =~ ^[0-9]+$ ]] && (( CTID >= 100 && CTID <= 999999999 )) \
      || die "Ungültige Container-ID: ${CTID}"
    if qm config "$CTID" >/dev/null 2>&1; then
      die "ID ${CTID} gehört zu einer VM, nicht zu einem LXC"
    fi
    if pct config "$CTID" >/dev/null 2>&1; then
      EXISTING_HOST="$(ctid_hostname "$CTID")"
      if [[ "${EXISTING_HOST,,}" == "${CT_HOSTNAME,,}" ]]; then
        msg_warn "CT ${CTID} (${CT_HOSTNAME}) existiert: Update-Modus"
        UPDATE_ONLY=1
      elif [[ "$FORCE" == "1" ]]; then
        msg_warn "CT ${CTID} (${EXISTING_HOST}) wird auf Wunsch entfernt"
        pct stop "$CTID" 2>/dev/null || true
        pct destroy "$CTID" --purge
      else
        die "CT ${CTID} existiert mit Hostname '${EXISTING_HOST}'. Andere ID wählen oder --force."
      fi
    fi
  else
    CTID="$(next_free_id)"
    msg_ok "Nächste freie CT-ID: ${CTID}"
  fi

  if [[ "$UPDATE_ONLY" == "0" ]]; then
    msg_info "Ressourcen: ${CORES} vCPU, ${RAM_MB} MiB RAM, ${DISK_GB} GiB Disk, Port ${APP_PORT}"
    if (( DISK_GB < 16 )); then
      msg_warn "${DISK_GB} GiB Disk können für den Node-/Vite-Build knapp werden; 16 GiB empfohlen"
    fi
    confirm "Container ${CTID} (${CT_HOSTNAME}) jetzt erstellen?" || die "Abgebrochen"
    TMP_DIR="$(mktemp -d)"
    fetch_asset "install/solooffice-inner.sh" "${TMP_DIR}/solooffice-inner.sh"
    fetch_asset "systemd/solooffice.service" "${TMP_DIR}/solooffice.service"
    fetch_asset "scripts/solooffice-env" "${TMP_DIR}/solooffice-env"
    fetch_asset "scripts/solooffice-stack" "${TMP_DIR}/solooffice-stack"
    create_container
    start_container
    wait_for_ct_ready
  else
    msg_info "Update-Modus für CT ${CTID}"
    start_container
    wait_for_ct_ready
    TMP_DIR="$(mktemp -d)"
    fetch_asset "install/solooffice-inner.sh" "${TMP_DIR}/solooffice-inner.sh"
    fetch_asset "systemd/solooffice.service" "${TMP_DIR}/solooffice.service"
    fetch_asset "scripts/solooffice-env" "${TMP_DIR}/solooffice-env"
    fetch_asset "scripts/solooffice-stack" "${TMP_DIR}/solooffice-stack"
  fi

  wait_for_ct_network
  ensure_onboot
  run_inner
  adopt_installed_port
  verify_from_host
  print_summary
}

SCRIPT_DIR=""
ROOT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

main "$@"
