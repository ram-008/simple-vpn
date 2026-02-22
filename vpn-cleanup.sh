#!/usr/bin/env bash
# Clean shutdown of all VPN interfaces

set -euo pipefail

# Colors
info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

echo ""
echo "=========================================="
echo "  Stopping All VPN Interfaces"
echo "=========================================="
echo ""

# Stop client interface
if sudo wg-quick down wg0 2>/dev/null; then
    ok "Client interface stopped (wg0)"
else
    warn "Client interface was not running"
fi

# Stop server interface
if sudo wg-quick down wg0 2>/dev/null; then
    ok "Server interface stopped (wg0)"
else
    warn "Server interface was not running"
fi

echo ""
info "Checking remaining interfaces..."
remaining=$(wg show interfaces 2>/dev/null || echo "")
if [[ -z "$remaining" ]]; then
    ok "All WireGuard interfaces are down"
else
    warn "Still running: $remaining"
    echo ""
    echo "To manually stop:"
    for iface in $remaining; do
        echo "  sudo wg-quick down $iface"
    done
fi

echo ""
echo "=========================================="
echo "  Cleanup Complete"
echo "=========================================="
echo ""
