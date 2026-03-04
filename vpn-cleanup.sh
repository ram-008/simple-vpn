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

# Enumerate all running WireGuard interfaces and stop each one.
# Previously this block hard-coded wg0 twice, so the second call always
# failed because the first already brought the interface down.
info "Detecting running WireGuard interfaces..."
mapfile -t running_ifaces < <(wg show interfaces 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)

if [[ ${#running_ifaces[@]} -eq 0 ]]; then
    warn "No WireGuard interfaces are currently running."
else
    for iface in "${running_ifaces[@]}"; do
        if sudo wg-quick down "$iface" 2>/dev/null; then
            ok "Interface stopped: $iface"
        else
            warn "Could not stop interface: $iface"
        fi
    done
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
    # Read into an array to avoid word-splitting on unusual interface names
    while IFS= read -r iface; do
        [[ -n "$iface" ]] && echo "  sudo wg-quick down $iface"
    done < <(echo "$remaining" | tr ' ' '\n')
fi

echo ""
echo "=========================================="
echo "  Cleanup Complete"
echo "=========================================="
echo ""
