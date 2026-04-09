#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run as root: sudo bash uninstall.sh"
    exit 1
fi

echo ""
echo "This will uninstall IncusAPI."
echo "(Incus itself will NOT be removed.)"
echo ""
read -p "Also remove config and database? (y/N): " REMOVE_DATA

# Stop and disable
if systemctl is-active --quiet incusapi 2>/dev/null; then
    systemctl stop incusapi
    info "Service stopped"
fi
if systemctl is-enabled --quiet incusapi 2>/dev/null; then
    systemctl disable incusapi >/dev/null 2>&1
    info "Service disabled"
fi

rm -f /etc/systemd/system/incusapi.service
systemctl daemon-reload 2>/dev/null
info "Service file removed"

rm -f /usr/local/bin/incusapi
info "Binary removed"

if [[ "$REMOVE_DATA" =~ ^[Yy]$ ]]; then
    rm -rf /etc/incusapi
    rm -rf /var/lib/incusapi
    info "Config and data removed"
else
    warn "Config (/etc/incusapi) and data (/var/lib/incusapi) kept."
fi

echo ""
info "IncusAPI uninstalled."
