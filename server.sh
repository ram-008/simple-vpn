#!/usr/bin/env bash
# =============================================================================
# server.sh — WireGuard VPN Server Setup
# =============================================================================
# This script configures the current machine as a WireGuard VPN server.
#
# What it does:
#   1. Generates a WireGuard keypair (private + public key)
#   2. Creates the WireGuard interface config at /etc/wireguard/wg0.conf
#   3. Enables IP forwarding so the server can route traffic between clients
#      and the internet
#   4. Sets up firewall rules (iptables) for NAT (Network Address Translation)
#   5. Brings up the WireGuard interface
#
# How WireGuard works (briefly):
#   WireGuard creates a virtual network interface (like wg0) that encrypts all
#   traffic sent through it. Each peer (server or client) has a keypair. Peers
#   authenticate each other using public keys — similar to SSH. Traffic is
#   encrypted using modern cryptography (ChaCha20, Curve25519, etc.) and sent
#   over UDP.
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

CONFIG_DIR="${HOME}/.simple-vpn"
WG_INTERFACE="wg0"

# VPN subnet — all VPN clients and the server get IPs from this range.
# 10.0.0.0/24 gives us 10.0.0.1 - 10.0.0.254 (254 usable addresses).
VPN_SUBNET="10.0.0.0/24"
SERVER_VPN_IP="10.0.0.1/24"

# Default UDP port for WireGuard. You can change this, but 51820 is standard.
LISTEN_PORT="51820"

# --- Helper Functions --------------------------------------------------------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Server setup requires root privileges. Run with: sudo $0"
    fi
}

detect_os() {
    # WireGuard works on both Linux and macOS, but the networking setup differs.
    case "$(uname -s)" in
        Linux*)  OS="linux" ;;
        Darwin*) OS="macos" ;;
        *)       error "Unsupported OS: $(uname -s). This script supports Linux and macOS." ;;
    esac
    info "Detected OS: $OS"
}

check_wireguard() {
    # WireGuard needs 'wg' (key management) and 'wg-quick' (interface management).
    if ! command -v wg &>/dev/null; then
        error "WireGuard tools not found. Install them first:
  Linux (Ubuntu/Debian): sudo apt install wireguard
  Linux (Fedora):        sudo dnf install wireguard-tools
  macOS:                 brew install wireguard-tools"
    fi
    ok "WireGuard tools found"
}

detect_public_interface() {
    # Find the network interface used to reach the internet.
    # This is needed for NAT rules so VPN traffic can be forwarded.
    if [[ "$OS" == "linux" ]]; then
        PUBLIC_IFACE=$(ip route show default | awk '{print $5}' | head -1)
    else
        PUBLIC_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    fi

    if [[ -z "${PUBLIC_IFACE:-}" ]]; then
        warn "Could not auto-detect public interface. Using 'eth0' as fallback."
        PUBLIC_IFACE="eth0"
    fi
    info "Public network interface: $PUBLIC_IFACE"
}

# --- Key Generation ----------------------------------------------------------

generate_keys() {
    # WireGuard uses Curve25519 keypairs. The private key is random, and the
    # public key is derived from it. This is the same concept as SSH keys, but
    # WireGuard keys are much shorter (32 bytes, base64-encoded).

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    # Fix ownership if running with sudo — ensure the config directory is owned
    # by the actual user, not root. This prevents permission errors when the
    # client script tries to use the same directory.
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$CONFIG_DIR"
    fi

    if [[ -f "$CONFIG_DIR/server_private.key" ]]; then
        warn "Server keys already exist in $CONFIG_DIR"
        warn "Reusing existing keys. Delete them to regenerate."
        SERVER_PRIVATE_KEY=$(cat "$CONFIG_DIR/server_private.key")
        SERVER_PUBLIC_KEY=$(cat "$CONFIG_DIR/server_public.key")
    else
        info "Generating server keypair..."
        SERVER_PRIVATE_KEY=$(wg genkey)
        SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

        # Private key must be readable only by root — it's the secret identity
        # of this server. Anyone with this key can impersonate the server.
        echo "$SERVER_PRIVATE_KEY" > "$CONFIG_DIR/server_private.key"
        chmod 600 "$CONFIG_DIR/server_private.key"

        echo "$SERVER_PUBLIC_KEY" > "$CONFIG_DIR/server_public.key"
        chmod 600 "$CONFIG_DIR/server_public.key"

        ok "Server keys generated"
    fi

    info "Server public key: $SERVER_PUBLIC_KEY"
}

# --- Server Configuration ----------------------------------------------------

create_server_config() {
    # The wg0.conf file tells WireGuard:
    #   [Interface] — settings for this machine (private key, IP, port)
    #   [Peer]      — each client that's allowed to connect
    #
    # PostUp/PostDown run shell commands when the interface goes up/down.
    # We use these to set up NAT so clients can reach the internet through
    # this server.

    info "Creating WireGuard server config..."

    # Ensure /etc/wireguard directory exists (especially needed on macOS)
    if [[ ! -d "/etc/wireguard" ]]; then
        mkdir -p "/etc/wireguard"
        chmod 700 "/etc/wireguard"
    fi

    if [[ "$OS" == "linux" ]]; then
        # iptables MASQUERADE: rewrites the source IP of VPN packets to the
        # server's public IP, so responses from the internet come back to us.
        POST_UP="iptables -t nat -A POSTROUTING -s $VPN_SUBNET -o $PUBLIC_IFACE -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT"
        POST_DOWN="iptables -t nat -D POSTROUTING -s $VPN_SUBNET -o $PUBLIC_IFACE -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT"
    else
        # macOS uses pf (packet filter) instead of iptables.
        POST_UP="echo 'nat on $PUBLIC_IFACE from $VPN_SUBNET to any -> ($PUBLIC_IFACE)' | pfctl -a com.wireguard -f - 2>/dev/null; pfctl -e 2>/dev/null || true"
        POST_DOWN="pfctl -a com.wireguard -F all 2>/dev/null || true"
    fi

    cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
# =============================================================================
# WireGuard Server Configuration
# Generated by simple-vpn on $(date)
# =============================================================================

[Interface]
# The server's private key — never share this!
PrivateKey = $SERVER_PRIVATE_KEY

# The server's IP address on the VPN network
Address = $SERVER_VPN_IP

# UDP port to listen on. Clients connect to this port.
ListenPort = $LISTEN_PORT

# NAT rules — applied when the interface comes up/down.
# These allow VPN clients to access the internet through this server.
PostUp = $POST_UP
PostDown = $POST_DOWN

# --- Peers are added below (one [Peer] block per client) ---
EOF

    chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"
    ok "Server config written to /etc/wireguard/${WG_INTERFACE}.conf"
}

# --- IP Forwarding -----------------------------------------------------------

enable_ip_forwarding() {
    # IP forwarding allows this machine to route packets between network
    # interfaces — essential for a VPN server. Without this, packets from
    # VPN clients would be received but not forwarded to the internet.

    if [[ "$OS" == "linux" ]]; then
        info "Enabling IPv4 forwarding..."
        sysctl -w net.ipv4.ip_forward=1 >/dev/null

        # Make it persistent across reboots
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
    else
        info "Enabling IP forwarding (macOS)..."
        sysctl -w net.inet.ip.forwarding=1 >/dev/null
    fi

    ok "IP forwarding enabled"
}

# --- Interface Management ----------------------------------------------------

start_interface() {
    # wg-quick is a helper that reads the config file, creates the virtual
    # interface, assigns the IP, sets up routes, and runs PostUp commands.

    if ip link show "$WG_INTERFACE" &>/dev/null 2>&1 || ifconfig "$WG_INTERFACE" &>/dev/null 2>&1; then
        warn "Interface $WG_INTERFACE already exists. Restarting..."
        wg-quick down "$WG_INTERFACE" 2>/dev/null || true
    fi

    info "Starting WireGuard interface..."
    wg-quick up "$WG_INTERFACE"
    ok "WireGuard interface $WG_INTERFACE is up"
}

# --- Add Peer ----------------------------------------------------------------

add_peer() {
    local client_pubkey="$1"
    local client_ip="$2"

    # Each client (peer) needs:
    #   PublicKey  — the client's public key (they generate this)
    #   AllowedIPs — which VPN IP this client is assigned (acts as both
    #                routing rule and access control)

    info "Adding peer: $client_ip ($client_pubkey)"

    cat >> "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF

[Peer]
# Client VPN IP: $client_ip
PublicKey = $client_pubkey
AllowedIPs = ${client_ip}/32
EOF

    # Hot-reload: add the peer without restarting the interface.
    # This avoids disconnecting existing clients.
    # On macOS, we need to find the actual interface name (e.g., utun6)
    local actual_interface="$WG_INTERFACE"
    if [[ "$OS" == "macos" ]]; then
        actual_interface=$(wg show interfaces 2>/dev/null | tr ' ' '\n' | head -1)
        if [[ -z "$actual_interface" ]]; then
            warn "Could not detect running interface. Using $WG_INTERFACE"
            actual_interface="$WG_INTERFACE"
        fi
    fi

    wg set "$actual_interface" peer "$client_pubkey" allowed-ips "${client_ip}/32"

    ok "Peer added successfully"
}

# --- Status ------------------------------------------------------------------

show_status() {
    echo ""
    echo "========================================"
    echo "  WireGuard Server Status"
    echo "========================================"

    # On macOS, detect the actual interface name
    local actual_interface="$WG_INTERFACE"
    if [[ "$OS" == "macos" ]]; then
        actual_interface=$(wg show interfaces 2>/dev/null | tr ' ' '\n' | head -1)
    fi

    if [[ -n "$actual_interface" ]] && wg show "$actual_interface" &>/dev/null; then
        wg show "$actual_interface"
    else
        echo "Interface $WG_INTERFACE is not running."
    fi

    echo "========================================"
    echo ""
}

# --- Main --------------------------------------------------------------------

main() {
    local action="${1:-setup}"

    case "$action" in
        setup)
            check_root
            detect_os
            check_wireguard
            detect_public_interface
            generate_keys
            create_server_config
            enable_ip_forwarding
            start_interface

            echo ""
            echo "========================================"
            echo "  VPN Server is running!"
            echo "========================================"
            echo ""
            echo "  Interface:   $WG_INTERFACE"
            echo "  VPN IP:      $SERVER_VPN_IP"
            echo "  Listen port: $LISTEN_PORT"
            echo "  Public key:  $SERVER_PUBLIC_KEY"
            echo ""
            echo "  Give clients your public key and"
            echo "  endpoint (your-server-ip:$LISTEN_PORT)"
            echo "  to connect."
            echo ""
            echo "  Add peers with:"
            echo "    sudo ./server.sh add-peer <pubkey> <vpn-ip>"
            echo ""
            echo "========================================"
            ;;
        add-peer)
            check_root
            detect_os
            if [[ $# -lt 3 ]]; then
                error "Usage: $0 add-peer <client-public-key> <client-vpn-ip>"
            fi
            add_peer "$2" "$3"
            ;;
        status)
            detect_os
            show_status
            ;;
        *)
            echo "Usage: $0 {setup|add-peer|status}"
            echo ""
            echo "  setup                              Configure and start VPN server"
            echo "  add-peer <client-pubkey> <vpn-ip>  Add a client peer"
            echo "  status                             Show server status"
            exit 1
            ;;
    esac
}

main "$@"
