#!/usr/bin/env bash
#
# local-smoke.sh - baut und startet SoloOffice lokal mit Docker Compose.
# Prüft damit den Upstream-Build, die Datenbank und die Web-UI, ohne Proxmox.
#
# Voraussetzungen: Docker Engine + Compose v2, curl, git, openssl.
#
set -euo pipefail

PORT=18080
SOURCE=""
KEEP=0
REPO_URL="https://github.com/TingelTangelBob/SoloOffice"
REPO_REF="main"
TMP_DIR=""

usage() {
  cat <<EOF
Lokaler Smoke-Test für SoloOffice

Usage: bash tests/local-smoke.sh [--port N] [--source DIR] [--ref REF] [--keep]

  --port N       Host-Port (Default: ${PORT})
  --source DIR   Lokaler SoloOffice-Checkout statt GitHub-Clone
  --ref REF      Git-Ref (Default: ${REPO_REF})
  --keep         Container und Verzeichnis nach dem Test behalten
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:?}"; shift 2 ;;
    --source) SOURCE="${2:?}"; shift 2 ;;
    --ref) REPO_REF="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unbekannte Option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

msg()  { printf '\033[1;34m[TEST]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 || { fail "docker fehlt"; exit 1; }
docker info >/dev/null 2>&1 || { fail "Docker-Daemon läuft nicht oder Zugriff fehlt"; exit 1; }
docker compose version >/dev/null 2>&1 || { fail "docker compose fehlt"; exit 1; }
command -v git >/dev/null 2>&1 || { fail "git fehlt"; exit 1; }
command -v openssl >/dev/null 2>&1 || { fail "openssl fehlt"; exit 1; }

cleanup() {
  if [[ "$KEEP" == "0" && -n "$TMP_DIR" && -d "$TMP_DIR/src" ]]; then
    msg "Räume Test-Stack ab"
    (cd "$TMP_DIR/src" && docker compose --env-file .env.solooffice -f docker-compose.yml down -v --remove-orphans) >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
  elif [[ -n "$TMP_DIR" ]]; then
    printf '\033[1;33m[WARN]\033[0m Testdaten behalten unter %s\n' "$TMP_DIR" >&2
  fi
}
trap cleanup EXIT

TMP_DIR="$(mktemp -d)"
SRC="${TMP_DIR}/src"

if [[ -n "$SOURCE" ]]; then
  msg "Kopiere lokalen Checkout ${SOURCE}"
  git clone --quiet --depth 1 "file://${SOURCE}" "$SRC"
else
  msg "Klonen ${REPO_URL} (${REPO_REF})"
  git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC"
fi

PW="$(openssl rand -hex 32)"
KEY="$(openssl rand -hex 32)"
ORIGIN="http://127.0.0.1:${PORT}"

cat >"${SRC}/.env.solooffice" <<EOF
COMPOSE_PROJECT_NAME=solooffice-smoke
INSTANCE_NAME=solooffice
FRONTEND_PORT=${PORT}
POSTGRES_DB=solooffice
POSTGRES_USER=solooffice
POSTGRES_PASSWORD=${PW}
ENCRYPTION_KEY=${KEY}
CORS_ORIGIN=${ORIGIN}
COOKIE_SECURE=false
COOKIE_SAME_SITE=lax
TRUST_PROXY=1
REGISTRATION_MODE=closed-after-first
REQUIRE_EMAIL_VERIFICATION=false
LOG_LEVEL=WARN
OCR_CONCURRENCY_LIMIT=1
OCR_TIMEOUT_MS=120000
EOF

cat >"${SRC}/.env.backend.solooffice" <<EOF
PORT=3001
DB_HOST=database
DB_PORT=5432
DB_NAME=solooffice
DB_USER=solooffice
DB_PASSWORD=${PW}
NODE_ENV=production
CORS_ORIGIN=${ORIGIN}
COOKIE_SECURE=false
COOKIE_SAME_SITE=lax
TRUST_PROXY=1
ENCRYPTION_KEY=${KEY}
REGISTRATION_MODE=closed-after-first
REQUIRE_EMAIL_VERIFICATION=false
APP_BASE_URL=${ORIGIN}
LOG_LEVEL=WARN
EOF
chmod 600 "${SRC}/.env.solooffice" "${SRC}/.env.backend.solooffice"

cd "$SRC"
compose=(docker compose --env-file .env.solooffice -f docker-compose.yml)

msg "Baue Images (kann 5–15 Minuten dauern)"
"${compose[@]}" build --pull

msg "Starte Stack"
"${compose[@]}" up -d

msg "Warte auf Web-UI und Datenbank"
ready=0
for _ in $(seq 1 150); do
  if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 \
    && "${compose[@]}" exec -T backend node -e \
      "fetch('http://127.0.0.1:3001/health/ready').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))" \
      >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "$ready" != "1" ]]; then
  echo "--- docker compose ps ---" >&2
  "${compose[@]}" ps -a >&2 || true
  echo "--- docker compose logs ---" >&2
  "${compose[@]}" logs --no-color --tail=200 >&2 || true
  fail "SoloOffice wurde nicht bereit"
  exit 1
fi

ok "Web-UI: ${ORIGIN}"
ok "Healthcheck: $(curl -fsS "http://127.0.0.1:${PORT}/healthz")"
"${compose[@]}" ps

msg "Smoke-Test bestanden"
