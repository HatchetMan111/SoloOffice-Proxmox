#!/usr/bin/env bash
#
# solooffice-inner.sh - Installation im LXC-Container.
# Wird vom Host-Installer nach /root/solooffice-inner.sh kopiert und dort
# ausgeführt. Direktaufruf im Container ist für Debugging vorgesehen:
#
#   bash /root/solooffice-inner.sh --debug --port 8080
#
set -euo pipefail
umask 077

APP="SoloOffice"
APP_ID="solooffice"
APP_PORT=8080
REPO_URL="https://github.com/TingelTangelBob/SoloOffice"
REPO_REF="main"
DNS_SERVERS=""
DEBUG=0
UPDATE=0
SET_PORT=0
UNIT_FILE="/root/solooffice.service"
ENV_SCRIPT="/root/solooffice-env"
STACK_SCRIPT="/root/solooffice-stack"
APP_DIR="/opt/solooffice"
ETC_DIR="/etc/solooffice"
LOG_FILE="/var/log/solooffice-install.log"

msg_info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
msg_ok()    { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
msg_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
msg_error() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }
die()       { msg_error "$*"; exit 1; }

usage() {
  cat <<EOF
${APP} - Container-Installer

Usage: bash solooffice-inner.sh [OPTIONEN]

  --port PORT            Web-Port (Default: ${APP_PORT})
  --repo URL             Upstream-Repository (Default: ${REPO_URL})
  --ref REF              Git-Ref (Default: ${REPO_REF})
  --dns LISTE            Kommagetrennte DNS-Server (Fallback)
  --unit-file DATEI      Pfad zur systemd-Unit im Container
  --env-script DATEI     Pfad zum Env-Renderer im Container
  --stack-script DATEI   Pfad zum Compose-Wrapper im Container
  --update               Update-Modus: Code aktualisieren, Secrets behalten
  --set-port             Mit --update: APP_PORT in config.env übernehmen
  --debug                bash -x mit Zeitstempeln
  --help                 Diese Hilfe
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) APP_PORT="${2:?--port benötigt einen Wert}"; shift 2 ;;
    --repo) REPO_URL="${2:?--repo benötigt einen Wert}"; shift 2 ;;
    --ref) REPO_REF="${2:?--ref benötigt einen Wert}"; shift 2 ;;
    --dns) DNS_SERVERS="${2:?--dns benötigt einen Wert}"; shift 2 ;;
    --unit-file) UNIT_FILE="${2:?--unit-file benötigt einen Wert}"; shift 2 ;;
    --env-script) ENV_SCRIPT="${2:?--env-script benötigt einen Wert}"; shift 2 ;;
    --stack-script) STACK_SCRIPT="${2:?--stack-script benötigt einen Wert}"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    --set-port) SET_PORT=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unbekannte Option: $1" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "Bitte als root im Container ausführen"
[[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )) \
  || die "Ungültiger Port: ${APP_PORT}"
[[ "$REPO_REF" =~ ^[^[:space:]]+$ ]] || die "Ungültiger Git-Ref: ${REPO_REF}"

docker_diagnostics() {
  {
    echo "--- docker --version ---"
    docker --version 2>&1 || true
    echo "--- docker info ---"
    docker info 2>&1 | tail -n 60 || true
    echo "--- systemctl status docker ---"
    systemctl status docker --no-pager -l 2>&1 || true
    echo "--- journalctl -u docker ---"
    journalctl -u docker -n 120 --no-pager 2>&1 || true
    echo "--- /etc/docker/daemon.json ---"
    cat /etc/docker/daemon.json 2>&1 || true
    echo "--- LXC-Features (auf dem Host prüfen) ---"
    echo "Erwartet: features: nesting=1,keyctl=1 und unprivileged"
  } >&2
}

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
    echo "--- Dienst solooffice ---"
    systemctl status solooffice --no-pager -l 2>&1 || true
    echo "--- journalctl -u solooffice (letzte 200 Zeilen) ---"
    journalctl -u solooffice -n 200 --no-pager 2>&1 || true
    echo "--- docker compose ps ---"
    if [[ -f /opt/solooffice/docker-compose.yml && -f /opt/solooffice/.env.solooffice ]]; then
      (cd /opt/solooffice && docker compose --env-file .env.solooffice -f docker-compose.yml ps -a 2>&1) || true
      echo "--- docker compose logs (letzte 200 Zeilen) ---"
      (cd /opt/solooffice && docker compose --env-file .env.solooffice -f docker-compose.yml logs --no-color --tail=200 2>&1) || true
    fi
    docker_diagnostics
    echo "--- Install-Log ${LOG_FILE} (letzte 160 Zeilen) ---"
    tail -n 160 "$LOG_FILE" 2>/dev/null || true
    echo "--- Speicher und Ports ---"
    df -h / /var/lib/docker 2>/dev/null || true
    free -m 2>/dev/null || true
    ss -tlnp 2>/dev/null || true
    echo
    echo "Nächster Schritt:"
    echo "  bash /root/solooffice-inner.sh --debug --port ${APP_PORT} $([[ "$UPDATE" == 1 ]] && echo --update)"
  } >&2
  exit "$code"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

install -d -m 0755 "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
if [[ "$DEBUG" == "1" ]]; then
  export PS4='+ $(date +%H:%M:%S) ${BASH_SOURCE##*/}:${LINENO}: '
  exec > >(tee -a "$LOG_FILE") 2>&1
  set -x
else
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

msg_info "${APP} Container-Installation"

ensure_dns() {
  # PVE kann /etc/resolv.conf unter dem Host-umask 077 anlegen. apts
  # Netzwerk-Methoden laufen als _apt und koennen eine 0600-Datei nicht lesen.
  [[ -e /etc/resolv.conf ]] && chmod 644 /etc/resolv.conf 2>/dev/null || true
  if getent hosts deb.debian.org >/dev/null 2>&1; then
    return 0
  fi
  local ns
  local -a list=()
  IFS=',' read -r -a list <<<"${DNS_SERVERS:-1.1.1.1,9.9.9.9}"
  {
    for ns in "${list[@]}"; do
      [[ -n "$ns" ]] && printf 'nameserver %s\n' "$ns"
    done
    printf 'options timeout:2 attempts:3\n'
  } > /etc/resolv.conf
  chmod 644 /etc/resolv.conf
  for _ in $(seq 1 20); do
    getent hosts deb.debian.org >/dev/null 2>&1 && return 0
    sleep 1
  done
  cat /etc/resolv.conf >&2 || true
  die "DNS im Container funktioniert nicht (deb.debian.org nicht auflösbar)"
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  msg_info "Paketlisten aktualisieren"
  apt-get update
  msg_info "Basis-Pakete installieren"
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git jq openssl fuse-overlayfs
  msg_ok "Basis-Pakete installiert"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    msg_ok "Docker und Compose sind bereits installiert"
  else
    msg_info "Docker CE installieren"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local arch codename
    arch="$(dpkg --print-architecture)"
    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-bookworm}")"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
      "$arch" "$codename" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    msg_ok "Docker CE installiert"
  fi

  if ! systemctl enable --now docker; then
    docker_diagnostics
    die "Docker-Dienst konnte nicht aktiviert werden"
  fi

  local ok=0
  for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  if [[ "$ok" == "1" ]]; then
    return 0
  fi

  msg_warn "Docker läuft nicht mit dem Standard-Storage-Treiber; versuche fuse-overlayfs"
  install -d -m 0755 /etc/docker
  if [[ -s /etc/docker/daemon.json ]] && jq -e . /etc/docker/daemon.json >/dev/null 2>&1; then
    jq '. + {"storage-driver": "fuse-overlayfs"}' /etc/docker/daemon.json >/etc/docker/daemon.json.tmp
    mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
  else
    printf '{"storage-driver": "fuse-overlayfs"}\n' >/etc/docker/daemon.json
  fi
  systemctl restart docker || true

  for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      msg_ok "Docker läuft mit fuse-overlayfs"
      return 0
    fi
    sleep 1
  done

  docker_diagnostics
  die "Docker läuft im Container nicht. Der LXC braucht features: nesting=1,keyctl=1 und muss unprivileged sein."
}

clone_repo() {
  msg_info "Upstream-Repository vorbereiten: ${REPO_URL} (${REPO_REF})"
  if [[ -d "$APP_DIR/.git" ]]; then
    git -C "$APP_DIR" remote set-url origin "$REPO_URL"
  else
    if [[ -e "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
      die "${APP_DIR} existiert bereits und ist kein Git-Checkout. Bitte manuell prüfen."
    fi
    rm -rf "$APP_DIR"
    git clone --no-checkout "$REPO_URL" "$APP_DIR"
  fi

  git -C "$APP_DIR" fetch --prune --tags origin

  if git -C "$APP_DIR" rev-parse --verify -q "origin/${REPO_REF}^{commit}" >/dev/null; then
    git -C "$APP_DIR" checkout -q -B "$REPO_REF" "origin/${REPO_REF}"
    git -C "$APP_DIR" reset --hard -q "origin/${REPO_REF}"
  elif git -C "$APP_DIR" rev-parse --verify -q "${REPO_REF}^{commit}" >/dev/null; then
    git -C "$APP_DIR" checkout -q --detach "$REPO_REF"
    git -C "$APP_DIR" reset --hard -q "$REPO_REF"
  else
    die "Git-Ref '${REPO_REF}' wurde im Upstream-Repository nicht gefunden"
  fi

  [[ -f "$APP_DIR/docker-compose.yml" ]] || die "docker-compose.yml fehlt in ${APP_DIR}"
  msg_ok "Code-Stand: $(git -C "$APP_DIR" rev-parse --short HEAD)"
}

write_config_and_secrets() {
  local tracing=0
  [[ "$-" == *x* ]] && tracing=1
  set +x

  install -d -m 0750 "$ETC_DIR" /var/lib/solooffice

  if [[ ! -s "$ETC_DIR/secrets.env" ]]; then
    msg_info "Erzeuge Datenbank-Passwort und Encryption-Key (einmalig)"
    (
      umask 077
      {
        printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)"
        printf 'ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)"
      } >"$ETC_DIR/secrets.env"
    )
    msg_ok "Secrets gespeichert: ${ETC_DIR}/secrets.env"
  else
    msg_ok "Bestehende Secrets bleiben unverändert"
  fi
  chmod 600 "$ETC_DIR/secrets.env"

  if [[ ! -s "$ETC_DIR/config.env" ]]; then
    cat >"$ETC_DIR/config.env" <<EOF
# SoloOffice-Betriebsdaten. Nach Änderungen: systemctl restart solooffice
APP_PORT=${APP_PORT}
# AUTO_ORIGIN=1 setzt CORS/APP_BASE_URL beim Start auf http://<CT-IP>:<Port>.
AUTO_ORIGIN=1
# Für Reverse-Proxy/HTTPS stattdessen die öffentliche Adresse eintragen:
# PUBLIC_ORIGIN=https://office.example.de
PUBLIC_ORIGIN=
TRUST_PROXY=1
REGISTRATION_MODE=closed-after-first
REQUIRE_EMAIL_VERIFICATION=false
LOG_LEVEL=WARN
OCR_CONCURRENCY_LIMIT=2
OCR_TIMEOUT_MS=120000
# SMTP ist optional; ohne SMTP gibt es keinen E-Mail-Versand.
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=
SMTP_PASS=
EMAIL_FROM=
EMAIL_FROM_NAME=SoloOffice
EOF
    chmod 600 "$ETC_DIR/config.env"
    msg_ok "Betriebsdaten angelegt: ${ETC_DIR}/config.env"
  else
    msg_ok "Bestehende Betriebsdaten bleiben unverändert"
  fi

  if [[ "$UPDATE" == "1" && "$SET_PORT" == "1" ]]; then
    if grep -q '^APP_PORT=' "$ETC_DIR/config.env"; then
      sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "$ETC_DIR/config.env"
    else
      printf 'APP_PORT=%s\n' "$APP_PORT" >>"$ETC_DIR/config.env"
    fi
    msg_ok "Port in ${ETC_DIR}/config.env auf ${APP_PORT} gesetzt"
  fi

  POSTGRES_PASSWORD="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$ETC_DIR/secrets.env" | tail -n 1)"
  ENCRYPTION_KEY="$(sed -n 's/^ENCRYPTION_KEY=//p' "$ETC_DIR/secrets.env" | tail -n 1)"
  [[ -n "$POSTGRES_PASSWORD" && -n "$ENCRYPTION_KEY" ]] \
    || die "Secrets in ${ETC_DIR}/secrets.env sind unvollständig"
  [[ "${#ENCRYPTION_KEY}" -eq 64 && "$ENCRYPTION_KEY" =~ ^[0-9a-fA-F]{64}$ ]] \
    || die "ENCRYPTION_KEY in ${ETC_DIR}/secrets.env muss 64 Hex-Zeichen haben"

  [[ "$tracing" == "1" ]] && set -x
  return 0
}

install_runtime() {
  [[ -f "$UNIT_FILE" ]] || die "systemd-Unit fehlt: ${UNIT_FILE}"
  [[ -f "$ENV_SCRIPT" ]] || die "Env-Script fehlt: ${ENV_SCRIPT}"
  [[ -f "$STACK_SCRIPT" ]] || die "Compose-Wrapper fehlt: ${STACK_SCRIPT}"

  msg_info "Installiere systemd-Unit und Wrapper"
  install -m 0644 "$UNIT_FILE" /etc/systemd/system/solooffice.service
  install -m 0755 "$ENV_SCRIPT" /usr/local/bin/solooffice-env
  install -m 0755 "$STACK_SCRIPT" /usr/local/bin/solooffice-stack
  systemctl daemon-reload
  msg_ok "Runtime-Dateien installiert"
}

write_version() {
  install -d -m 0755 "$ETC_DIR"
  {
    printf 'SOLOOFFICE_VERSION=%s\n' "$(git -C "$APP_DIR" describe --tags --always 2>/dev/null || echo dev)"
    printf 'SOLOOFFICE_COMMIT_SHA=%s\n' "$(git -C "$APP_DIR" rev-parse HEAD)"
  } >"$ETC_DIR/version"
  chmod 644 "$ETC_DIR/version"
}

build_images() {
  msg_info "Rendere Compose-Konfiguration"
  /usr/local/bin/solooffice-env
  chmod 600 "$APP_DIR/.env.${APP_ID}" "$APP_DIR/.env.backend.${APP_ID}"

  msg_info "Baue Docker-Images (Node, nginx, PostgreSQL; kann 5–15 Minuten dauern)"
  (
    cd "$APP_DIR"
    SOLOOFFICE_VERSION="$(sed -n 's/^SOLOOFFICE_VERSION=//p' "$ETC_DIR/version" | tail -n 1)"
    SOLOOFFICE_COMMIT_SHA="$(sed -n 's/^SOLOOFFICE_COMMIT_SHA=//p' "$ETC_DIR/version" | tail -n 1)"
    export SOLOOFFICE_VERSION SOLOOFFICE_COMMIT_SHA
    docker compose --env-file ".env.${APP_ID}" -f docker-compose.yml build --pull
  )
  msg_ok "Images gebaut"
}

activate_service() {
  msg_info "Aktiviere und starte solooffice.service"
  systemctl enable solooffice >/dev/null
  systemctl restart solooffice
  msg_ok "Dienst gestartet"
}

verify_install() {
  msg_info "Prüfe Dienst, Web-UI und Datenbank"
  systemctl is-active --quiet solooffice || {
    systemctl status solooffice --no-pager -l 2>&1 || true
    die "solooffice.service ist nicht aktiv"
  }
  if ! /usr/local/bin/solooffice-stack verify; then
    die "Verifikation fehlgeschlagen (Details oben)"
  fi
  systemctl is-active --quiet solooffice || die "Dienst ist nach der Verifikation nicht aktiv"
  msg_ok "Dienst aktiv; Web-UI und Backend antworten"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${APP_PORT}/tcp" >/dev/null 2>&1 || true
    msg_ok "ufw-Regel für Port ${APP_PORT}/tcp gesetzt"
  fi
}

main() {
  ensure_dns
  install_base_packages
  install_docker
  clone_repo
  write_config_and_secrets
  write_version
  install_runtime
  build_images
  activate_service
  verify_install
  open_firewall

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  cat <<EOF

  ${APP} ist installiert.

  Web-UI:      http://${ip:-<CT-IP>}:${APP_PORT}
  Erster Login: ersten Benutzer registrieren (wird Administrator).
  Dienst:      systemctl status solooffice
  Logs:        journalctl -u solooffice -f
  Betrieb:     ${ETC_DIR}/config.env (Secrets: secrets.env)
  Update:      bash /root/solooffice-inner.sh --update
EOF
}

main "$@"
