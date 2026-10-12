#!/usr/bin/env bash
#
# Worklenz Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:     Worklenz – All-in-one Projektmanagement (Frontend :5000 + Backend :3000 via Nginx :80)
# Upstream: https://github.com/Worklenz/worklenz
# Stack:   React/Express (offizielle Docker-Images) + PostgreSQL 15 + SeaweedFS + Nginx
# Läuft:   vollständig lokal im LXC, keine Cloud nötig
# Host:    DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WorkLenz-Proxmox/main/install/worklenz.sh)"
#   CT_ID=101 CORES=2 RAM=4096 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WorkLenz-Proxmox/main/install/worklenz.sh)"
#   bash worklenz.sh --ctid 101 --cores 2 --memory 4096 --disk 20 --bridge vmbr0 --debug
#
# Hinweis: Worklenz besteht aus 7+ Containern (Frontend, Backend, Client-Portal,
# Postgres, SeaweedFS, Configure, Nginx, DB-Backup). Darum weicht der Standard
# (2 vCPU / 4096 MB / 20 GB) bewusst von der 1–2-GB-Faustregel ab – mit 2 GB
# läuft Postgres + Node-Dienste in OOM.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="worklenz"                               # Container-Hostname + Service-Name
FRONTEND_PORT="5000"                         # Worklenz Frontend direkt
BACKEND_PORT="3000"                          # Worklenz Backend/API direkt
PORTAL_PORT="5174"                           # Worklenz Client-Portal direkt
S3_PORT="8333"                               # SeaweedFS S3-API
HTTP_PORT="80"                               # Primäre Web-UI via Nginx
HTTPS_PORT="443"                             # HTTPS via Nginx (optional)
FRONTEND_IMAGE="chamikajaycey/worklenz-frontend:3.2.0"
BACKEND_IMAGE="chamikajaycey/worklenz-backend:3.2.0"
POSTGRES_IMAGE="postgres:15"
SEAWEEDFS_IMAGE="chrislusf/seaweedfs:4.41"
UPSTREAM_REPO="https://github.com/Worklenz/worklenz.git"

DEFAULT_CORES="2"                            # vCPU
DEFAULT_RAM="4096"                           # RAM in MB (Minimum für den Stack)
DEFAULT_SWAP="1024"                          # Swap (MB)
DEFAULT_DISK="20"                            # Disk in GB (Images + DB, min. 12)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"               # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"              # Template-Familie (Docker-getestet)
UNPRIVILEGED="1"
FEATURES="nesting=1,keyctl=1"                # nesting/keyctl = Docker im LXC nötig

# Erst-Admin (wird per App-Signup-API angelegt + in Schluss-Box gedruckt)
# team_name ist Pflichtfeld der Signup-API (3.2.0-Code, sonst "Team name is required").
DEFAULT_ADMIN_EMAIL="admin@worklenz.local"
DEFAULT_ADMIN_NAME="Worklenz Admin"
DEFAULT_ADMIN_TEAM="Worklenz"

# Umgebungs-Overrides erlauben: CT_ID=101 CORES=4 RAM=8192 DISK=20 ./worklenz.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
ADMIN_EMAIL_ARG="${ADMIN_EMAIL:-}"
ADMIN_PASSWORD_ARG="${ADMIN_PASSWORD:-}"
ADMIN_NAME_ARG="${ADMIN_NAME:-}"
ADMIN_TEAM_ARG="${ADMIN_TEAM:-}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe zusätzlich ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
msg_info "Upstream-Images: $FRONTEND_IMAGE / $BACKEND_IMAGE / $POSTGRES_IMAGE / $SEAWEEDFS_IMAGE (Ports: UI=$HTTP_PORT/$HTTPS_PORT, Frontend=$FRONTEND_PORT, API=$BACKEND_PORT, Portal=$PORTAL_PORT, S3=$S3_PORT)"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash worklenz.sh [OPTIONEN]
  CT_ID=101 bash worklenz.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WorkLenz-Proxmox/main/install/worklenz.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum 4096 empfohlen)
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --admin-email MAIL   Erst-Admin-Mail (Default: admin@worklenz.local)
  --admin-password PW  Erst-Admin-Passwort (Default: zufällig generiert, Policy-konform)
  --admin-name NAME    Erst-Admin-Name (Default: Worklenz Admin)
  --admin-team TEAM    Erst-Admin-Team (Default: Worklenz, Pflichtfeld der Signup-API)
  --debug, -x          set -x + maximale Fehlermeldungskette
  --help, -h           diese Hilfe

Nach der Installation:
  Web-UI:  https://<LXC-IP>  (Nginx, primär, self-signed – Warnung bestätigen)
  Health:  http://<LXC-IP>:${HTTP_PORT}/health (ohne Redirect, 200)
  Direkt:  http://<LXC-IP>:${FRONTEND_PORT} (Frontend), :${BACKEND_PORT} (API),
           :${PORTAL_PORT} (Portal), :${S3_PORT} (S3)
EOF
}

# ---------------------------------------------------------------------------
# Debugging: komplette Fehlermeldungskette (Stacktrace, stderr/stdout, Exit-Code, Logs)
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +x
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}… [gekürzt, vollständiger Befehl in $LOG_FILE]"
  fi
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $SCRIPT_ARGS"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]]; then
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- systemctl status im Container (worklenz) ---"
    pct exec "${CTID}" -- systemctl status "${APP}" --no-pager --full 2>&1 || true
    echo ""
    msg_error "--- journalctl im Container (worklenz, letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u "${APP}" --no-pager -n 100 2>&1 || true
    echo ""
    msg_error "--- docker ps im Container ---"
    pct exec "${CTID}" -- docker ps -a 2>&1 || true
    echo ""
    msg_error "--- docker compose logs (letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- docker compose -f /opt/worklenz/docker-compose.yml logs --tail=100 --no-color 2>&1 || true
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  msg_error "  bash -x worklenz.sh $SCRIPT_ARGS"
  msg_error "  oder: DEBUG=1 bash worklenz.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CT_ID_ARG"
HOSTNAME_ARG="$APP"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
DISK="$DISK_ARG"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY=""
ADMIN_EMAIL="$ADMIN_EMAIL_ARG"
ADMIN_PASSWORD="$ADMIN_PASSWORD_ARG"
ADMIN_NAME="$ADMIN_NAME_ARG"
ADMIN_TEAM="$ADMIN_TEAM_ARG"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)            CTID="${2:?--ctid braucht einen Wert}"; shift 2 ;;
    --hostname)        HOSTNAME_ARG="${2:?--hostname braucht einen Wert}"; shift 2 ;;
    --cores)           CORES="${2:?}"; shift 2 ;;
    --memory)          RAM="${2:?}"; shift 2 ;;
    --disk)            DISK="${2:?}"; shift 2 ;;
    --storage)         STORAGE_ARG="${2:?}"; shift 2 ;;
    --template-store)  TEMPLATE_STORE="${2:?}"; shift 2 ;;
    --bridge)          BRIDGE="${2:?}"; shift 2 ;;
    --password)        ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --ssh-key)         SSH_KEY="${2:?}"; shift 2 ;;
    --admin-email)     ADMIN_EMAIL="${2:?--admin-email braucht einen Wert}"; shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="${2:?--admin-password braucht einen Wert}"; shift 2 ;;
    --admin-name)      ADMIN_NAME="${2:?--admin-name braucht einen Wert}"; shift 2 ;;
    --admin-team)      ADMIN_TEAM="${2:?--admin-team braucht einen Wert}"; shift 2 ;;
    --debug|-x)        DEBUG="1"; set -x; shift ;;
    --help|-h)         usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

# Trap NACH dem Parsen setzen, damit SCRIPT_ARGS die echten Args enthält
# shellcheck disable=SC2064
trap "on_error \$? \$LINENO \"\$BASH_COMMAND\"" ERR

# ---------------------------------------------------------------------------
# Pre-Checks (muss auf dem Proxmox-Host als root laufen)
# ---------------------------------------------------------------------------
msg_info "Prüfe Voraussetzungen (Proxmox-Host, root, Tools) ..."
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausführen (sudo -i)."
  exit 1
fi
for bin in pct pveam pvesh pvesm wget curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    msg_error "Benötigtes Tool fehlt: $bin – läuft das Skript wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
done
if [[ "$RAM" -lt 4096 ]]; then
  msg_warn "RAM=${RAM} MB < 4096 MB – Worklenz (Frontend+Backend+Postgres+SeaweedFS+Nginx) braucht min. 4 GB, sonst OOM."
fi
if [[ "$DISK" -lt 12 ]]; then
  msg_warn "DISK=${DISK} GB < 12 GB – Docker-Images + DB brauchen min. ~12 GB."
fi
msg_ok "Host-Checks bestanden."

# ---------------------------------------------------------------------------
# CT-ID: immer die nächste freie ID nehmen (außer explizit gesetzt)
# ---------------------------------------------------------------------------
if [[ -z "$CTID" ]]; then
  msg_info "Ermittle nächste freie CT-ID ..."
  CTID="$(pvesh get /cluster/nextid)"
  msg_ok "Nächste freie CT-ID: $CTID"
else
  msg_info "CT-ID vorgegeben: $CTID"
fi

HOSTNAME_FINAL="$HOSTNAME_ARG"
if [[ ! "$HOSTNAME_FINAL" =~ ^[a-zA-Z0-9-]+$ ]]; then
  msg_error "Ungültiger Hostname: $HOSTNAME_FINAL (nur Buchstaben, Zahlen, Bindestrich)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Storage-Erkennung (idempotent: vorhandene Storages nutzen)
# ---------------------------------------------------------------------------
detect_storage() {
  local s
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | grep -x "local-lvm" || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | head -n1 || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  echo "local-lvm"
}
if [[ -z "$STORAGE_ARG" ]]; then
  STORAGE_ARG="$(detect_storage)"
  msg_info "RootFS-Storage (auto): $STORAGE_ARG"
else
  msg_info "RootFS-Storage (vorgegeben): $STORAGE_ARG"
fi

# ---------------------------------------------------------------------------
# Template sicherstellen
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Template-Liste (pveam update) ..."
pveam update

msg_info "Suche neuestes ${DEFAULT_OS}-Template auf ${TEMPLATE_STORE} ..."
TEMPLATE_FILE="$(pveam available --section system 2>/dev/null \
  | grep -o "${DEFAULT_OS}[^ ]*\\.tar\\.zst" | sort -V | tail -n1 || true)"
if [[ -z "$TEMPLATE_FILE" ]]; then
  msg_error "Kein Template für ${DEFAULT_OS} gefunden. Verfügbare Debian-Templates:"
  pveam available --section system 2>&1 | grep -i debian || true
  exit 1
fi
TEMPLATE_REF="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_FILE}"
msg_info "Template: $TEMPLATE_REF"
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE_FILE"; then
  msg_info "Lade Template herunter (kann dauern) ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_FILE"
else
  msg_ok "Template bereits vorhanden – Download übersprungen (idempotent)."
fi

# ---------------------------------------------------------------------------
# Container erstellen (idempotent: existiert die CT-ID schon, wiederverwenden)
# ---------------------------------------------------------------------------
CREATED_NOW=0
GENERATED_PW=0
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "Container $CTID existiert bereits – wird wiederverwendet (idempotent, kein Neu-Erstellen)."
  EXISTING_HOST="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}' || true)"
  msg_info "Bestehender Hostname: ${EXISTING_HOST:-unbekannt}"
else
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(openssl rand -hex 8)"
    GENERATED_PW=1
  fi
  msg_info "Erstelle LXC $CTID (hostname=${HOSTNAME_FINAL}, cores=${CORES}, ram=${RAM}MB, disk=${DISK}G) ..."
  CREATE_ARGS=(
    "$CTID" "$TEMPLATE_REF"
    --hostname "$HOSTNAME_FINAL"
    --cores "$CORES"
    --memory "$RAM"
    --swap "$DEFAULT_SWAP"
    --rootfs "${STORAGE_ARG}:${DISK}"
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
    --ostype debian
    --unprivileged "$UNPRIVILEGED"
    --features "$FEATURES"
    --onboot 1
    --start 0
    --password "$ROOT_PASSWORD"
  )
  if [[ -n "$SSH_KEY" ]]; then
    if [[ ! -f "$SSH_KEY" ]]; then msg_error "SSH-Key nicht gefunden: $SSH_KEY"; exit 1; fi
    CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY")
  fi
  pct create "${CREATE_ARGS[@]}"
  # onboot + nesting explizit sicherstellen (Reboot-sicher, Docker-fähig)
  pct set "$CTID" --onboot 1 --features "$FEATURES"
  CREATED_NOW=1
  msg_ok "Container $CTID erstellt (Name: $HOSTNAME_FINAL, onboot=1, features=$FEATURES)."
fi

msg_info "Starte Container $CTID ..."
if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
  pct start "$CTID"
fi
for i in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "$i" -eq 30 ]]; then msg_error "Container $CTID reagiert nicht auf 'pct exec'."; exit 1; fi
done
msg_ok "Container $CTID läuft."

sleep 5

# ---------------------------------------------------------------------------
# Installation IM Container (idempotentes Setup-Skript via pct push + exec)
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP} im Container (Docker + Upstream-Stack: Frontend/Backend/Postgres/SeaweedFS/Nginx) ..."

# systemd-Unit-Vorlage (identisch zu systemd/worklenz.service im Repo)
read -r -d '' UNIT_FILE <<'UNIT_EOF' || true
[Unit]
Description=Worklenz – All-in-one Projektmanagement (Docker Compose: Frontend + Backend + Postgres + SeaweedFS + Nginx)
Documentation=https://github.com/Worklenz/worklenz
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/worklenz
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_EOF

# Erst-Admin-Defaults auflösen (Passwort Policy-konform: min. 8 Zeichen,
# Klein-/Großbuchstabe, Ziffer, Sonderzeichen – vgl. SignupPage-Regeln)
if [[ -z "$ADMIN_EMAIL" ]]; then ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL"; fi
if [[ -z "$ADMIN_NAME" ]]; then ADMIN_NAME="$DEFAULT_ADMIN_NAME"; fi
if [[ -z "$ADMIN_TEAM" ]]; then ADMIN_TEAM="$DEFAULT_ADMIN_TEAM"; fi
if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="Apw-$(openssl rand -hex 10)!9"
fi
# Base64-Transport in den Container (sonderzeichensicher, kein Eval/Quote-Bruch)
ADMIN_PASSWORD_B64="$(printf '%s' "$ADMIN_PASSWORD" | base64 -w0)"
# Zeichen, die Heredoc-Expansion ("$", Backtick) oder JSON (" , \) brechen,
# werden abgelehnt (Allowlist-Pruefung, kein Backslash-Literal noetig).
# Generiertes Default-Passwort enthaelt nur Allowlist-Zeichen.
for _av in "$ADMIN_EMAIL" "$ADMIN_NAME" "$ADMIN_TEAM" "$ADMIN_PASSWORD"; do
  _kept="$(printf '%s' "$_av" | tr -cd 'A-Za-z0-9@._+! #%*=?^{|}~,:;()/=-')"
  if [[ "$_kept" != "$_av" ]]; then
    msg_error "Admin-Wert mit unzulässigen Zeichen: '${_av:0:30}...' – erlaubt: Buchstaben/Ziffern/Leerzeichen plus @._+! #%*=?^~,:;()/=- (kein \" \\ \$ Backtick [ ] & ' \` + = |)."
    exit 1
  fi
done

# Setup-Skript lokal bauen (Host-Variablen werden HIER expandiert,
# Container-Variablen sind mit \$ escaped und werden ERST im LXC expandiert).
TMP_SETUP="$(mktemp /tmp/worklenz-setup.XXXXXX.sh)"
cat > "$TMP_SETUP" <<SETUP_EOF
#!/usr/bin/env bash
set -euo pipefail
APP="${APP}"
FRONTEND_PORT="${FRONTEND_PORT}"
BACKEND_PORT="${BACKEND_PORT}"
HTTP_PORT="${HTTP_PORT}"
UPSTREAM_REPO="${UPSTREAM_REPO}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
ADMIN_PASSWORD_B64="${ADMIN_PASSWORD_B64}"
ADMIN_NAME="${ADMIN_NAME}"
ADMIN_TEAM="${ADMIN_TEAM}"

echo "[LXC] apt update + Basis-Pakete ..."
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
echo "[LXC] APT-Quellen prüfen/normalisieren (Template-Ablage) ..."
echo "[LXC] --- /etc/apt/sources.list (vorher) ---"
cat /etc/apt/sources.list 2>/dev/null || true
# Manche Debian-12-Templates enthalten die veraltete Security-URL ohne
# /debian-security-Pfad (-> GPG-Fehler "no longer signed", apt Exit 100).
# Idempotent normalisieren (nach dem Fix matcht das Pattern nicht mehr):
sed -i 's|http://security.debian.org bookworm-security|http://security.debian.org/debian-security bookworm-security|g' /etc/apt/sources.list 2>/dev/null || true
sed -i 's|http://security.debian.org bookworm-security|http://security.debian.org/debian-security bookworm-security|g' /etc/apt/sources.list.d/* 2>/dev/null || true
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates openssl iproute2 procps git

echo "[LXC] Docker sicherstellen (idempotent) ..."
DOCKER_OK=0
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "[LXC] Docker + Compose bereits vorhanden: \$(docker --version) / \$(docker compose version --short)"
  DOCKER_OK=1
fi
if [[ "\$DOCKER_OK" != "1" ]]; then
  echo "[LXC] Installiere Docker aus dem offiziellen Docker-Repo ..."
  apt-get install -y --no-install-recommends gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 --max-time 60 https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  DARCH="\$(dpkg --print-architecture)"
  DCODENAME="\$(. /etc/os-release && echo "\$VERSION_CODENAME")"
  echo "deb [arch=\$DARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$DCODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  if apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
    echo "[LXC] Docker aus offiziellem Repo installiert."
  else
    echo "[LXC][WARN] Offizielles Docker-Repo fehlgeschlagen – Fallback: docker.io + Compose-Plugin-Binary von GitHub."
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y --no-install-recommends docker.io
    CMACHINE="\$(uname -m)"
    case "\$CMACHINE" in
      x86_64) CMARCH="x86_64" ;;
      aarch64|arm64) CMARCH="aarch64" ;;
      *) echo "[LXC][ERROR] Nicht unterstützte Architektur für Compose-Fallback: \$CMACHINE" >&2; exit 1 ;;
    esac
    mkdir -p /usr/libexec/docker/cli-plugins
    curl -fSL --retry 3 --max-time 180 -o /usr/libexec/docker/cli-plugins/docker-compose "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-\$CMARCH"
    chmod +x /usr/libexec/docker/cli-plugins/docker-compose
  fi
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
fi
docker --version
docker compose version

echo "[LXC] Container-IP ermitteln (fuer DOMAIN / URLs) ..."
LXC_IP="\$(ip -4 -o addr show eth0 2>/dev/null | awk '\$4 !~ /^127\\./ {print \$4}' | cut -d/ -f1 | head -n1 || true)"
if [[ -z "\$LXC_IP" ]]; then
  LXC_IP="\$(ip -4 -o addr show 2>/dev/null | awk '\$2 != "lo" && \$4 !~ /^127\\./ {print \$4}' | cut -d/ -f1 | head -n1 || true)"
fi
if [[ -z "\$LXC_IP" ]]; then
  echo "[LXC][ERROR] Keine IPv4-Adresse gefunden." >&2
  ip -4 -o addr show >&2 || true
  exit 1
fi
echo "[LXC] Container-IP: \$LXC_IP"

echo "[LXC] Upstream-Checkout nach /opt/worklenz (idempotent) ..."
if [[ -d /opt/worklenz/.git ]]; then
  git -C /opt/worklenz pull --ff-only origin main || echo "[LXC][WARN] git pull fehlgeschlagen – nutze bestehenden Checkout."
else
  rm -rf /opt/worklenz
  git clone --depth 1 --branch main "\$UPSTREAM_REPO" /opt/worklenz
fi
cd /opt/worklenz

echo "[LXC] .env vorbereiten (idempotent, Secrets bleiben erhalten) ..."
if [[ ! -f /opt/worklenz/.env ]]; then
  cp /opt/worklenz/.env.example /opt/worklenz/.env
  echo "[LXC] .env aus .env.example angelegt."
else
  echo "[LXC] Bestehende .env gefunden – Secrets werden wiederverwendet."
fi
gen_hex() { openssl rand -hex 32; }
ensure_secret() {
  local key="\$1"
  local cur=""
  cur="\$(grep -E "^\$key=" /opt/worklenz/.env | head -n1 | cut -d= -f2- || true)"
  if [[ -z "\$cur" || "\$cur" == *"CHANGE_THIS"* ]]; then
    local nv="\$(gen_hex)"
    if grep -qE "^\$key=" /opt/worklenz/.env; then
      sed -i "s|^\$key=.*|\$key=\$nv|" /opt/worklenz/.env
    else
      printf '%s=%s\n' "\$key" "\$nv" >> /opt/worklenz/.env
    fi
    echo "[LXC] Secret \$key (neu) generiert."
  fi
}
ensure_secret DB_PASSWORD
ensure_secret SESSION_SECRET
ensure_secret COOKIE_SECRET
ensure_secret JWT_SECRET
ensure_secret S3_SECRET_ACCESS_KEY
ensure_secret REDIS_PASSWORD
# URLs zeigen IMMER auf die aktuelle Container-IP (DHCP-Wechsel-safe)
set_url() {
  local key="\$1" val="\$2"
  if grep -qE "^\$key=" /opt/worklenz/.env; then
    sed -i "s|^\$key=.*|\$key=\$val|" /opt/worklenz/.env
  else
    printf '%s=%s\n' "\$key" "\$val" >> /opt/worklenz/.env
  fi
}
set_url DOMAIN "\$LXC_IP"
# Upstream-Konvention (manage.sh auto_configure_env): alles https/wss auf die
# Domain/IP – sonst Mixed-Content-Block (https-Seite ruft http-API) + :80-Redirect.
set_url VITE_API_URL "https://\$LXC_IP"
set_url VITE_SOCKET_URL "wss://\$LXC_IP"
set_url FRONTEND_URL "https://\$LXC_IP"
set_url SERVER_CORS "https://\$LXC_IP"
set_url SOCKET_IO_CORS "https://\$LXC_IP"
set_url S3_PUBLIC_URL "http://\$LXC_IP:${S3_PORT}/worklenz-bucket"
set_url WORKLENZ_DEPLOYMENT_MODE "self_hosted"
set_url DEPLOYMENT_MODE "express"
chmod 0600 /opt/worklenz/.env
echo "[LXC] .env aktualisiert (DOMAIN=\$LXC_IP)."

echo "[LXC] SSL-Zertifikat sicherstellen (Upstream: self-signed, wie manage.sh setup_self_signed_ssl) ..."
mkdir -p /opt/worklenz/nginx/ssl
if [[ ! -f /opt/worklenz/nginx/ssl/cert.pem || ! -f /opt/worklenz/nginx/ssl/key.pem ]]; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /opt/worklenz/nginx/ssl/key.pem \
    -out /opt/worklenz/nginx/ssl/cert.pem \
    -subj "/C=US/ST=State/L=City/O=Worklenz/CN=localhost"
  chmod 644 /opt/worklenz/nginx/ssl/cert.pem
  chmod 600 /opt/worklenz/nginx/ssl/key.pem
  echo "[LXC] Self-signed Zertifikat erzeugt (Browser-Warnung bestaetigen)."
else
  echo "[LXC] SSL-Zertifikat bereits vorhanden – wird wiederverwendet."
fi

echo "[LXC] systemd-Unit schreiben ..."
cat > /etc/systemd/system/worklenz.service <<UNIT_INNER_EOF
${UNIT_FILE}
UNIT_INNER_EOF
systemctl daemon-reload
systemctl enable worklenz

echo "[LXC] Images ziehen (kann beim ersten Mal dauern) ..."
cd /opt/worklenz
docker compose pull || {
  echo "[LXC][WARN] 'docker compose pull' meldete Fehler – versuche trotzdem zu starten." >&2
  docker images >&2 || true
}

echo "[LXC] Stack (neu) starten ..."
if systemctl is-active --quiet worklenz; then
  systemctl restart worklenz
else
  systemctl start worklenz
fi
sleep 10
# --force-recreate: .env-Aenderungen (URLs/Secrets) erreichen die Container nur
# bei Neuerstellung (Entrypoint laeuft erneut: env-config.sh, DB-Env). Volumes bleiben.
docker compose up -d --force-recreate
sleep 5

wait_for_http() {
  local label="\$1" url="\$2"
  local i code
  for i in \$(seq 1 120); do
    code="\$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "\$url" 2>/dev/null || true)"
    [[ -z "\$code" ]] && code="000"
    if [[ "\$code" != "000" ]]; then
      echo "[LXC] \$label antwortet (HTTP \$code auf \$url)."
      return 0
    fi
    if [[ \$((i % 12)) -eq 0 ]]; then echo "[LXC] ... warte auf \$label (\$((i*2))s), docker ps:"; docker ps --format '{{.Names}} {{.Status}}' || true; fi
    sleep 2
  done
  echo "[LXC][ERROR] \$label antwortet nicht auf \$url (keine TCP/HTTP-Antwort)." >&2
  return 1
}

echo "[LXC] Warte auf Nginx (http://127.0.0.1:\$HTTP_PORT/health, max 240s) ..."
if ! wait_for_http "Nginx (/health)" "http://127.0.0.1:\$HTTP_PORT/health"; then
  echo "[LXC][ERROR] Nginx-Diagnose:" >&2
  systemctl status worklenz --no-pager --full >&2 || true
  journalctl -u worklenz --no-pager -n 100 >&2 || true
  docker ps -a >&2 || true
  docker compose logs --tail=100 --no-color >&2 || true
  exit 1
fi

echo "[LXC] Warte auf Frontend (http://127.0.0.1:\$FRONTEND_PORT, max 240s) ..."
if ! wait_for_http "Frontend" "http://127.0.0.1:\$FRONTEND_PORT"; then
  echo "[LXC][ERROR] Frontend-Diagnose:" >&2
  docker compose logs --tail=100 --no-color >&2 || true
  exit 1
fi

echo "[LXC] Warte auf Backend (http://127.0.0.1:\$BACKEND_PORT/public/health, max 240s) ..."
if ! wait_for_http "Backend (/public/health)" "http://127.0.0.1:\$BACKEND_PORT/public/health"; then
  echo "[LXC][ERROR] Backend-Diagnose:" >&2
  docker compose logs --tail=100 --no-color >&2 || true
  exit 1
fi

# --- Erst-Admin anlegen (idempotent, ueber die app-eigene Signup-API) ---
# 3.2.0-Route (im Image verifiziert: app.use("/secure", authRouter)):
# POST /secure/signup mit {"name","email","password","team_name"} – team_name ist
# Pflichtfeld ("Team name is required"), Route steht auf der CSRF-Ausnahmeliste,
# daher kein Token/Flow noetig. Dadurch stimmen Validierung, Hash und Org-Anlage
# garantiert (kein SQL-Hack ins DB-Schema).
rm -f /tmp/worklenz-admin-creds
if [[ -f /opt/worklenz/.admin-created ]]; then
  echo "[LXC] Erst-Admin bereits angelegt (\$(cat /opt/worklenz/.admin-created 2>/dev/null || echo unbekannt)) – wird nicht erneut erstellt."
else
  # Vorab-Pruefung in der DB (Tabellen/Spalten aus Login-Strategie belegt):
  # Existiert die Mail schon (z. B. manuell angelegt), wird NICHTS ueberschrieben
  # und kein falsches Passwort gedruckt.
  DBU="\$(grep -E '^DB_USER=' /opt/worklenz/.env | head -n1 | cut -d= -f2)"; DBU="\${DBU:-postgres}"
  DBN="\$(grep -E '^DB_NAME=' /opt/worklenz/.env | head -n1 | cut -d= -f2)"; DBN="\${DBN:-worklenz_db}"
  if docker compose exec -T db psql -U "\$DBU" -d "\$DBN" -tAc "SELECT 1 FROM users WHERE LOWER(email)=LOWER('\$ADMIN_EMAIL') LIMIT 1" 2>/dev/null | grep -q 1; then
    printf '%s\n' "\$ADMIN_EMAIL" > /opt/worklenz/.admin-created
    chmod 600 /opt/worklenz/.admin-created
    echo "[LXC][WARN] Admin-Mail \$ADMIN_EMAIL existiert bereits in der DB – kein neuer Account (mit dem urspruenglichen Passwort anmelden)."
  else
  ADMIN_PW="\$(printf '%s' "\$ADMIN_PASSWORD_B64" | base64 -d)"
  SIGNUP_JSON="{\"name\":\"\$ADMIN_NAME\",\"email\":\"\$ADMIN_EMAIL\",\"password\":\"\$ADMIN_PW\",\"team_name\":\"\$ADMIN_TEAM\"}"
  SIGNUP_OUT="\$(mktemp)"
  SIGNUP_CODE="\$(curl -s -o "\$SIGNUP_OUT" -w "%{http_code}" --max-time 30 -H "Content-Type: application/json" -d "\$SIGNUP_JSON" "http://127.0.0.1:\$BACKEND_PORT/secure/signup" 2>/dev/null || true)"
  [[ -z "\$SIGNUP_CODE" ]] && SIGNUP_CODE="000"
  echo "[LXC] Signup-Antwort (HTTP \$SIGNUP_CODE): \$(head -c 500 "\$SIGNUP_OUT" 2>/dev/null | tr '\n' ' ' || true)"
  if grep -q '"done":true' "\$SIGNUP_OUT" 2>/dev/null || { [[ "\$SIGNUP_CODE" == "302" ]] && grep -qi 'secure/verify' "\$SIGNUP_OUT" 2>/dev/null; }; then
    printf '%s\n' "\$ADMIN_EMAIL" > /opt/worklenz/.admin-created
    chmod 600 /opt/worklenz/.admin-created
    { printf '%s\n' "\$ADMIN_EMAIL"; printf '%s\n' "\$ADMIN_PW"; } > /tmp/worklenz-admin-creds
    chmod 600 /tmp/worklenz-admin-creds
    echo "[LXC] Erst-Admin angelegt: \$ADMIN_EMAIL (Zugangsdaten zeigt die Host-Schluss-Box)."
  elif grep -qi 'already\|exists\|vergeben\|registered' "\$SIGNUP_OUT" 2>/dev/null; then
    printf '%s\n' "\$ADMIN_EMAIL" > /opt/worklenz/.admin-created
    chmod 600 /opt/worklenz/.admin-created
    echo "[LXC][WARN] Admin-Mail existiert bereits – kein neuer Account (Passwort aus Erstlauf verwenden)."
  else
    echo "[LXC][WARN] Erst-Admin konnte nicht angelegt werden – manuell im Browser registrieren (Name mind. 4 Zeichen, Passwort mind. 8 Zeichen mit Gross-/Kleinbuchstabe, Ziffer + Sonderzeichen @\\$!%*?&#)."
  fi
  rm -f "\$SIGNUP_OUT"
  unset ADMIN_PW
  fi
fi
echo "[LXC] Service aktiv: \$(systemctl is-active worklenz)"
echo "[LXC] Container: \$(docker ps --format '{{.Names}} {{.Status}}' | tr '\\n' '; ')"
SETUP_EOF

chmod 0644 "$TMP_SETUP"
msg_info "Setup-Skript lokal: $TMP_SETUP (Kopie bleibt zur Fehlersuche erhalten)"
pct push "$CTID" "$TMP_SETUP" /tmp/worklenz-setup.sh
pct exec "$CTID" -- bash /tmp/worklenz-setup.sh
msg_ok "Installation im Container abgeschlossen."

# Erst-Login aus dem Container abholen (nur-Erstlauf-Passwort, transient).
# Die Datei wird im Container sofort wieder gelöscht; die Box unten druckt
# einmalig, das Host-Log enthält sie (sicher verwahren/löschen).
ADMIN_CREDS_EMAIL=""
ADMIN_CREDS_PW=""
if pct exec "$CTID" -- test -f /tmp/worklenz-admin-creds 2>/dev/null; then
  ADMIN_CREDS_EMAIL="$(pct exec "$CTID" -- sed -n '1p' /tmp/worklenz-admin-creds 2>/dev/null || true)"
  ADMIN_CREDS_PW="$(pct exec "$CTID" -- sed -n '2p' /tmp/worklenz-admin-creds 2>/dev/null || true)"
  pct exec "$CTID" -- rm -f /tmp/worklenz-admin-creds || true
fi

# ---------------------------------------------------------------------------
# Verifikation vom Host aus (Service + HTTP + IP)
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."

SERVICE_STATE="$(pct exec "$CTID" -- systemctl is-active "$APP" 2>&1 || true)"
if [[ "$SERVICE_STATE" != "active" ]]; then
  msg_error "Service-Check fehlgeschlagen: 'systemctl is-active $APP' = '$SERVICE_STATE' (erwartet: active)"
  pct exec "$CTID" -- systemctl status "$APP" --no-pager --full || true
  pct exec "$CTID" -- journalctl -u "$APP" --no-pager -n 100 || true
  pct exec "$CTID" -- docker ps -a || true
  exit 1
fi
msg_ok "Service läuft (systemctl is-active $APP = active)."

NGINX_CODE="$(pct exec "$CTID" -- curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:${HTTP_PORT}/health" 2>/dev/null || true)"
[[ -z "$NGINX_CODE" ]] && NGINX_CODE="000"
if [[ "$NGINX_CODE" == "000" ]]; then
  msg_error "HTTP-Check fehlgeschlagen: Nginx http://127.0.0.1:${HTTP_PORT}/health antwortet nicht (keine Verbindung)."
  pct exec "$CTID" -- docker compose -f /opt/worklenz/docker-compose.yml logs --tail=100 --no-color || true
  exit 1
fi
msg_ok "Nginx antwortet (HTTP $NGINX_CODE auf localhost:${HTTP_PORT}/health)."

FRONTEND_CODE="$(pct exec "$CTID" -- curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:${FRONTEND_PORT}" 2>/dev/null || true)"
[[ -z "$FRONTEND_CODE" ]] && FRONTEND_CODE="000"
if [[ "$FRONTEND_CODE" == "000" ]]; then
  msg_error "HTTP-Check fehlgeschlagen: Frontend http://127.0.0.1:${FRONTEND_PORT} antwortet nicht (keine Verbindung)."
  pct exec "$CTID" -- docker compose -f /opt/worklenz/docker-compose.yml logs --tail=100 --no-color || true
  exit 1
fi
msg_ok "Frontend antwortet (HTTP $FRONTEND_CODE auf localhost:${FRONTEND_PORT})."

BACKEND_CODE="$(pct exec "$CTID" -- curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:${BACKEND_PORT}/public/health" 2>/dev/null || true)"
[[ -z "$BACKEND_CODE" ]] && BACKEND_CODE="000"
if [[ "$BACKEND_CODE" == "000" ]]; then
  msg_error "HTTP-Check fehlgeschlagen: Backend http://127.0.0.1:${BACKEND_PORT}/public/health antwortet nicht (keine Verbindung)."
  pct exec "$CTID" -- docker compose -f /opt/worklenz/docker-compose.yml logs --tail=100 --no-color || true
  exit 1
fi
msg_ok "Backend antwortet (HTTP $BACKEND_CODE auf localhost:${BACKEND_PORT}/public/health)."

CT_IP="$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
[[ -z "$CT_IP" ]] && CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

echo ""
echo -e "${C_GREEN}${C_BOLD}════════════════ INSTALLATION ERFOLGREICH ════════════════${C_RESET}"
echo -e "  App          : ${C_BOLD}Worklenz – All-in-one Projektmanagement${C_RESET}"
echo -e "  Container    : CT ${C_BOLD}${CTID}${C_RESET} (Hostname: ${C_BOLD}${HOSTNAME_FINAL}${C_RESET}, onboot=1)"
echo -e "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
if [[ -n "${ADMIN_CREDS_PW:-}" ]]; then
echo -e "  Erst-Login   : ${C_BOLD}${ADMIN_CREDS_EMAIL} / ${ADMIN_CREDS_PW}${C_RESET} (nur jetzt angezeigt – nach Login aendern!)"
elif ADMIN_MARKER="$(pct exec "$CTID" -- cat /opt/worklenz/.admin-created 2>/dev/null || true)"; [[ -n "$ADMIN_MARKER" ]]; then
echo -e "  Erst-Login   : ${ADMIN_MARKER} (bereits angelegt – Passwort aus Erstlauf verwenden)"
else
echo -e "  Erst-Login   : im Browser registrieren (https://<LXC-IP> -> Sign up; Name mind. 4 Zeichen, starkes Passwort)"
fi
if [[ -n "${CT_IP:-}" ]]; then
echo -e "  Web-UI       : ${C_BOLD}https://${CT_IP}${C_RESET} (Nginx, primaer, self-signed – Browser-Warnung bestaetigen)"
echo -e "  Health       : http://${CT_IP}:${HTTP_PORT}/health"
echo -e "  Frontend     : ${C_BOLD}http://${CT_IP}:${FRONTEND_PORT}${C_RESET} (direkt)"
echo -e "  API          : http://${CT_IP}:${BACKEND_PORT}"
echo -e "  Portal       : http://${CT_IP}:${PORTAL_PORT}"
echo -e "  S3           : http://${CT_IP}:${S3_PORT}"
else
echo -e "  Web-UI       : ${C_BOLD}https://<LXC-IP>${C_RESET} (IP konnte nicht auto-ermittelt werden: pct exec $CTID -- ip a)"
fi
if [[ "$CREATED_NOW" == "1" && "$GENERATED_PW" == "1" ]]; then
echo -e "  Root-Passwort: ${C_BOLD}${ROOT_PASSWORD}${C_RESET} (nur jetzt angezeigt – sicher ablegen!)"
fi
echo -e "  Service      : systemctl status ${APP}  (im Container via: pct enter ${CTID})"
echo -e "  Stack        : cd /opt/worklenz && docker compose ps / docker compose logs -f (im Container)"
echo -e "  Update       : Skript erneut laufen lassen (idempotent, zieht neueste Images + restart)"
echo -e "  Deinstall    : pct stop ${CTID} && pct destroy ${CTID}"
echo -e "  Reboot-Test  : pct reboot ${CTID} && sleep 90 && curl -fs http://${CT_IP:-<LXC-IP>}:${HTTP_PORT}/health >/dev/null && curl -fs http://${CT_IP:-<LXC-IP>}:${FRONTEND_PORT} >/dev/null"
echo -e "  Log          : ${LOG_FILE}"
echo -e "  Setup-Kopie  : ${TMP_SETUP}"
if [[ "$DEBUG" != "1" ]]; then
echo -e "  Debug bei Fehlern: ${C_CYAN}bash -x worklenz.sh --ctid ${CTID}${C_RESET}"
fi
echo -e "${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
