#!/bin/bash
set -e

# IncusAPI One-Click Installer
#
# Usage:
#   Fresh install / Clean reinstall (removes old data):
#     curl -sSL https://raw.githubusercontent.com/csh733/incusapi-release/master/install.sh | sudo bash
#
#   Upgrade only (keep config & database):
#     curl -sSL https://raw.githubusercontent.com/csh733/incusapi-release/master/install.sh | sudo bash -s -- --upgrade

APP_NAME="incusapi"
REPO="csh733/incusapi-release"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/incusapi"
DATA_DIR="/var/lib/incusapi"
SERVICE_FILE="/etc/systemd/system/incusapi.service"
PORT=8080

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}[$1/$TOTAL_STEPS]${NC} $2"; }

TOTAL_STEPS=5

# ─── Parse arguments ─────────────────────────────────────

MODE="clean"
for arg in "$@"; do
    case "$arg" in
        --upgrade) MODE="upgrade" ;;
        --clean)   MODE="clean" ;;
        --help|-h)
            echo "Usage:"
            echo "  bash install.sh           # Fresh/clean install (default)"
            echo "  bash install.sh --upgrade # Keep config & database, only replace binary"
            echo "  bash install.sh --clean   # Remove all old data and reinstall"
            exit 0
            ;;
    esac
done

# ─── Pre-checks ──────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    error "Please run as root (sudo)"
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
else
    OS_ID="unknown"
fi
info "Detected OS: $OS_ID $OS_VERSION ($(uname -m))"

ARCH=$(uname -m)
case $ARCH in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac

# ─── Handle existing installation ────────────────────────

if [ -f "$DATA_DIR/incusapi.db" ] || [ -f "$CONFIG_DIR/config.yaml" ]; then
    if [ "$MODE" = "clean" ]; then
        warn "Existing installation found. Clean reinstall: removing old data..."
        systemctl stop incusapi 2>/dev/null || true
        rm -f "$DATA_DIR/incusapi.db"
        rm -f "$DATA_DIR/.initial_credentials"
        rm -f "$CONFIG_DIR/config.yaml"
        info "Old config and database removed"
    else
        info "Upgrade mode: keeping existing config and database"
        systemctl stop incusapi 2>/dev/null || true
    fi
else
    info "Fresh installation"
fi

# ─────────────────────────────────────────────────────────
step 1 "Installing system dependencies"
# ─────────────────────────────────────────────────────────

install_pkg() {
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "$@" >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$@" >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q "$@" >/dev/null 2>&1
    else
        error "Unsupported package manager. Install manually: $*"
    fi
}

for pkg in curl jq wget file; do
    if ! command -v $pkg &>/dev/null; then
        info "Installing $pkg..."
        install_pkg $pkg
    fi
done
info "Dependencies ready"

# ─────────────────────────────────────────────────────────
step 2 "Installing Incus"
# ─────────────────────────────────────────────────────────

if command -v incus &>/dev/null; then
    INCUS_VER=$(incus version 2>/dev/null || echo "unknown")
    info "Incus already installed: $INCUS_VER"
else
    info "Installing Incus..."

    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop)
            if [ ! -f /etc/apt/sources.list.d/zabbly-incus-stable.sources ] && \
               [ ! -f /etc/apt/sources.list.d/zabbly-incus-stable.list ]; then
                curl -fsSL https://pkgs.zabbly.com/get/incus-stable | bash 2>&1 | tail -5
            fi
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf copr enable -y neil/incus 2>/dev/null || true
                dnf install -y incus incus-client 2>&1 | tail -5
            else
                error "Please install Incus manually on $OS_ID"
            fi
            ;;
        *)
            warn "Auto-install not supported for $OS_ID."
            warn "Install Incus manually: https://linuxcontainers.org/incus/docs/main/installing/"
            ;;
    esac

    if command -v incus &>/dev/null; then
        INCUS_VER=$(incus version 2>/dev/null || echo "unknown")
        info "Incus installed: $INCUS_VER"
    else
        warn "Incus installation may have failed. IncusAPI will run but Incus features won't work."
    fi
fi

# ─── Incus initial setup ─────────────────────────────────

if command -v incus &>/dev/null; then
    POOLS=$(incus storage list --format csv 2>/dev/null | wc -l)
    if [ "$POOLS" -eq 0 ]; then
        info "Initializing Incus with default settings..."
        cat <<PRESEED | incus admin init --preseed 2>/dev/null || true
config: {}
networks:
- config:
    ipv4.address: auto
    ipv6.address: auto
  description: ""
  name: incusbr0
  type: bridge
storage_pools:
- config: {}
  description: ""
  driver: dir
  name: default
profiles:
- config: {}
  description: Default profile
  devices:
    eth0:
      name: eth0
      network: incusbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
PRESEED
        info "Incus initialized (storage: dir, network: incusbr0)"
    else
        info "Incus already initialized ($POOLS storage pool(s))"
    fi
fi

# ─────────────────────────────────────────────────────────
step 3 "Installing IncusAPI binary"
# ─────────────────────────────────────────────────────────

mkdir -p "$CONFIG_DIR" "$DATA_DIR"
BINARY_PATH="$INSTALL_DIR/$APP_NAME"

systemctl stop incusapi 2>/dev/null || true

DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/incusapi-linux-${ARCH}"
info "Downloading incusapi-linux-${ARCH}..."
curl -sSL -o "$BINARY_PATH" "$DOWNLOAD_URL" || error "Download failed from $DOWNLOAD_URL"
chmod +x "$BINARY_PATH"

if ! file "$BINARY_PATH" | grep -q "ELF"; then
    FTYPE=$(file "$BINARY_PATH")
    rm -f "$BINARY_PATH"
    error "Downloaded file is not a valid Linux binary: $FTYPE"
fi

SIZE=$(du -h "$BINARY_PATH" | awk '{print $1}')
info "Binary installed: $BINARY_PATH ($SIZE)"

# ─────────────────────────────────────────────────────────
step 4 "Configuring IncusAPI"
# ─────────────────────────────────────────────────────────

if [ ! -f "$CONFIG_DIR/config.yaml" ]; then
    SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '=+/\n' | head -c 32)
    cat > "$CONFIG_DIR/config.yaml" <<EOF
server:
  host: "0.0.0.0"
  port: $PORT
  secret: "$SECRET"

incus:
  socket: ""

database:
  path: "$DATA_DIR/incusapi.db"

log:
  level: "info"

branding:
  site_name: "IncusAPI"
  logo_url: ""
EOF
    info "Config created: $CONFIG_DIR/config.yaml"
else
    info "Config exists, keeping current config"
fi

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=IncusAPI Web Management Server
After=network-online.target incus.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/$APP_NAME -config $CONFIG_DIR/config.yaml
Restart=always
RestartSec=5
LimitNOFILE=65536
WorkingDirectory=$DATA_DIR
StandardOutput=journal
StandardError=journal
SyslogIdentifier=incusapi

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable incusapi >/dev/null 2>&1
info "Systemd service configured"

# ─────────────────────────────────────────────────────────
step 5 "Opening firewall and starting service"
# ─────────────────────────────────────────────────────────

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow $PORT/tcp >/dev/null 2>&1 && info "ufw: port $PORT opened"
fi
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    info "firewalld: port $PORT opened"
fi
if command -v iptables &>/dev/null; then
    if ! iptables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null && \
            info "iptables: port $PORT opened"
    fi
fi

systemctl start incusapi
sleep 3

if ! systemctl is-active --quiet incusapi; then
    echo ""
    warn "Service failed to start. Recent logs:"
    journalctl -u incusapi -n 15 --no-pager
    error "Check the logs above."
fi

info "Service is running!"

# ─── Read credentials ────────────────────────────────────

CRED_FILE="$DATA_DIR/.initial_credentials"
ADMIN_USER=""
ADMIN_PW=""
if [ -f "$CRED_FILE" ]; then
    ADMIN_USER=$(sed -n '1p' "$CRED_FILE")
    ADMIN_PW=$(sed -n '2p' "$CRED_FILE")
    rm -f "$CRED_FILE"
fi

# ─── Result ──────────────────────────────────────────────

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP="<server-ip>"

echo ""
echo "════════════════════════════════════════════"
echo "  IncusAPI installed successfully!"
echo ""
echo "  Web UI:     http://${SERVER_IP}:${PORT}"
echo ""
if [ -n "$ADMIN_PW" ]; then
    echo "  Username:   ${ADMIN_USER}"
    echo "  Password:   ${ADMIN_PW}"
elif [ "$MODE" = "upgrade" ]; then
    echo "  (Upgrade mode: credentials unchanged)"
else
    echo "  (Credentials unchanged — database already existed)"
fi
echo ""
echo "  Config:     $CONFIG_DIR/config.yaml"
echo "  Database:   $DATA_DIR/incusapi.db"
echo "  Logs:       journalctl -u incusapi -f"
echo ""
echo "  Upgrade:    curl -sSL ...install.sh | sudo bash -s -- --upgrade"
echo "  Uninstall:  curl -sSL ...uninstall.sh | sudo bash"
echo "════════════════════════════════════════════"
