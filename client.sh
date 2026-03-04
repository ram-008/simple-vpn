#!/usr/bin/env bash
# =============================================================================
# client.sh — WireGuard VPN Client Setup
# =============================================================================
# This script configures the current machine as a WireGuard VPN client.
#
# What it does:
#   1. Generates a client keypair (private + public key)
#   2. Creates a WireGuard config file pointing to the server
#   3. Brings up/down the VPN tunnel
#
# How the client-server handshake works:
#   1. Client sends an encrypted "initiation" message to the server's UDP port
#   2. Server verifies the client's public key against its [Peer] list
#   3. If authorized, server responds and a secure tunnel is established
#   4. All subsequent traffic is encrypted with session keys derived from the
#      initial handshake (using Noise protocol framework)
#   5. WireGuard sends keepalive packets to maintain the connection through NAT
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

CONFIG_DIR="${HOME}/.simple-vpn"
WG_INTERFACE="wg0"

# The next available VPN IP. In a real deployment, the server would assign
# this. For simplicity, you set it when running client-setup.
DEFAULT_CLIENT_IP="10.0.0.2/24"

# DNS server to use when tunneling all traffic through the VPN.
# 1.1.1.1 = Cloudflare, 8.8.8.8 = Google. Using VPN DNS prevents DNS leaks.
DNS_SERVER="1.1.1.1"

# --- Helper Functions --------------------------------------------------------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

detect_os() {
    case "$(uname -s)" in
        Linux*)  OS="linux" ;;
        Darwin*) OS="macos" ;;
        *)       error "Unsupported OS: $(uname -s)" ;;
    esac
}

check_wireguard() {
    if ! command -v wg &>/dev/null; then
        error "WireGuard tools not found. Install them first:
  Linux (Ubuntu/Debian): sudo apt install wireguard
  Linux (Fedora):        sudo dnf install wireguard-tools
  macOS:                 brew install wireguard-tools"
    fi
    ok "WireGuard tools found"
}

# --- Input Validation --------------------------------------------------------

validate_pubkey() {
    local key="$1" label="${2:-public key}"
    # WireGuard public keys are exactly 44-character base64 strings (32 bytes + '=' padding)
    if [[ ! "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        error "Invalid WireGuard $label: '$key'. Expected a 44-character base64 string."
    fi
}

validate_ipv4_cidr() {
    local input="$1" label="${2:-IP/CIDR}"
    local addr="${input%%/*}"
    local prefix="${input##*/}"
    if [[ ! "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        error "Invalid $label: '$input'."
    fi
    IFS='.' read -ra octets <<< "$addr"
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            error "Invalid $label: '$input' (octet $octet out of range)."
        fi
    done
    if [[ "$input" == */* ]] && ! [[ "$prefix" =~ ^([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        error "Invalid CIDR prefix in $label: '$input'."
    fi
}

validate_endpoint() {
    local endpoint="$1"
    # Accept host:port or [ipv6addr]:port
    # Host part: alphanumeric, dots, hyphens, brackets (IPv6)
    # Port part: 1–65535
    if [[ ! "$endpoint" =~ ^(\[?[a-zA-Z0-9._:-]+\]?):([0-9]{1,5})$ ]]; then
        error "Invalid server endpoint: '$endpoint'. Expected format: host:port or ip:port."
    fi
    local port="${BASH_REMATCH[2]}"
    if (( port < 1 || port > 65535 )); then
        error "Invalid port in endpoint: '$port'. Must be 1–65535."
    fi
}

# --- Key Generation ----------------------------------------------------------

generate_keys() {
    # Same as the server — each peer (client or server) has its own keypair.
    # The client's public key needs to be registered on the server as a [Peer].

    # Check if config directory exists with wrong ownership (created by sudo)
    if [[ -d "$CONFIG_DIR" ]] && [[ ! -w "$CONFIG_DIR" ]]; then
        warn "Config directory exists but is not writable. Fixing permissions..."
        sudo chown -R "$(whoami):$(id -gn)" "$CONFIG_DIR"
        ok "Permissions fixed"
    fi

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    if [[ -f "$CONFIG_DIR/client_private.key" ]]; then
        warn "Client keys already exist in $CONFIG_DIR"
        warn "Reusing existing keys. Delete them to regenerate."
        CLIENT_PRIVATE_KEY=$(cat "$CONFIG_DIR/client_private.key")
        CLIENT_PUBLIC_KEY=$(cat "$CONFIG_DIR/client_public.key")
    else
        info "Generating client keypair..."
        CLIENT_PRIVATE_KEY=$(wg genkey)
        CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

        echo "$CLIENT_PRIVATE_KEY" > "$CONFIG_DIR/client_private.key"
        chmod 600 "$CONFIG_DIR/client_private.key"

        echo "$CLIENT_PUBLIC_KEY" > "$CONFIG_DIR/client_public.key"
        chmod 600 "$CONFIG_DIR/client_public.key"

        ok "Client keys generated"
    fi

    info "Client public key: $CLIENT_PUBLIC_KEY"
    echo ""
    echo "  >>> Give this public key to the server admin to add you as a peer <<<"
    echo ""
}

# --- Client Configuration ----------------------------------------------------

create_client_config() {
    local server_pubkey="$1"
    local server_endpoint="$2"
    local client_ip="${3:-$DEFAULT_CLIENT_IP}"
    local tunnel_mode="${4:-full}"

    # Validate all user-supplied values before they are written into the
    # WireGuard config.  Without validation an attacker could inject newlines
    # followed by PostUp directives; those directives execute as root when
    # wg-quick brings the interface up.
    validate_pubkey      "$server_pubkey"   "server public key"
    validate_endpoint    "$server_endpoint"
    validate_ipv4_cidr   "$client_ip"       "client VPN IP"

    # AllowedIPs controls what traffic goes through the VPN tunnel:
    #
    #   Full tunnel  (0.0.0.0/0):   ALL traffic goes through VPN — maximum
    #                                 privacy, but all bandwidth goes through
    #                                 the server.
    #
    #   Split tunnel (10.0.0.0/24):  Only traffic to VPN peers goes through
    #                                 the tunnel. Internet traffic goes through
    #                                 your normal connection. Less private, but
    #                                 faster for general browsing.

    if [[ "$tunnel_mode" == "full" ]]; then
        ALLOWED_IPS="0.0.0.0/0, ::/0"
        DNS_LINE="DNS = $DNS_SERVER"
        info "Mode: Full tunnel (all traffic routed through VPN)"
    else
        ALLOWED_IPS="10.0.0.0/24"
        DNS_LINE="# DNS not overridden in split tunnel mode"
        info "Mode: Split tunnel (only VPN traffic routed)"
    fi

    local config_file="$CONFIG_DIR/${WG_INTERFACE}.conf"

    # Build the config content once and write it to both destinations atomically.
    #
    # Security: do NOT write to a user-writable path first and then sudo-copy it.
    # That pattern creates a TOCTOU window: between the write and the sudo cp,
    # any process running as the same user could replace the file with a version
    # containing a malicious PostUp directive that executes as root via wg-quick.
    #
    # Instead we capture the content in a variable and pipe it to both the
    # user-space copy (for reference) and the system config in one pass.

    local config_content
    config_content="$(cat <<EOF
# =============================================================================
# WireGuard Client Configuration
# Generated by simple-vpn on $(date)
# =============================================================================

[Interface]
# This client's private key
PrivateKey = $CLIENT_PRIVATE_KEY

# This client's IP address on the VPN network
Address = $client_ip

# DNS server to use (prevents DNS leaks when using full tunnel)
$DNS_LINE

[Peer]
# The VPN server's public key — authenticates the server
PublicKey = $server_pubkey

# Server address and port
Endpoint = $server_endpoint

# What traffic to send through the tunnel
# Full tunnel: 0.0.0.0/0, ::/0 (everything)
# Split tunnel: 10.0.0.0/24 (VPN network only)
AllowedIPs = $ALLOWED_IPS

# Send a keepalive packet every 25 seconds.
# This is essential when behind NAT — it keeps the UDP "connection" alive
# in the NAT table. Without this, the NAT mapping expires and the server
# can no longer reach the client.
PersistentKeepalive = 25
EOF
)"

    # Write user-space reference copy
    printf '%s\n' "$config_content" > "$config_file"
    chmod 600 "$config_file"
    ok "Client config written to $config_file"

    # Write system config directly via sudo tee — no intermediate user-writable
    # file is ever copied with elevated privileges, eliminating the TOCTOU race.
    echo ""
    info "Installing config to /etc/wireguard/ (requires sudo)..."
    sudo mkdir -p /etc/wireguard
    printf '%s\n' "$config_content" | sudo tee "/etc/wireguard/${WG_INTERFACE}.conf" > /dev/null
    sudo chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"
    ok "Config installed to /etc/wireguard/${WG_INTERFACE}.conf"
}

# --- Connection Management ---------------------------------------------------

disable_ipv6_macos() {
    info "Disabling IPv6 to prevent leaks..."
    networksetup -listallnetworkservices | grep -v "^An asterisk" | while read -r svc; do
        sudo networksetup -setv6off "$svc" 2>/dev/null
    done
    ok "IPv6 disabled"
}

restore_ipv6_macos() {
    info "Re-enabling IPv6..."
    networksetup -listallnetworkservices | grep -v "^An asterisk" | while read -r svc; do
        sudo networksetup -setv6automatic "$svc" 2>/dev/null
    done
    ok "IPv6 re-enabled"
}

connect() {
    # wg-quick reads the config, creates the interface, assigns the IP,
    # sets up routing, and applies DNS settings.

    if ip link show "$WG_INTERFACE" &>/dev/null 2>&1 || ifconfig "$WG_INTERFACE" &>/dev/null 2>&1; then
        warn "VPN is already connected. Use 'disconnect' first to reconnect."
        return 0
    fi

    [[ "$OS" == "macos" ]] && disable_ipv6_macos

    info "Connecting to VPN..."
    sudo wg-quick up "$WG_INTERFACE"
    ok "VPN connected!"
    echo ""
    show_status
}

disconnect() {
    info "Disconnecting from VPN..."
    sudo wg-quick down "$WG_INTERFACE" 2>/dev/null || warn "VPN was not connected."
    ok "VPN disconnected"

    [[ "$OS" == "macos" ]] && restore_ipv6_macos
}

show_status() {
    echo "========================================"
    echo "  WireGuard Client Status"
    echo "========================================"

    # On macOS, detect the actual interface name
    local actual_interface="$WG_INTERFACE"
    if [[ "$OS" == "macos" ]]; then
        actual_interface=$(wg show interfaces 2>/dev/null | tr ' ' '\n' | head -1)
    fi

    if [[ -n "$actual_interface" ]] && sudo wg show "$actual_interface" &>/dev/null; then
        sudo wg show "$actual_interface"
    else
        echo "  Interface $WG_INTERFACE is not running."
    fi

    echo "========================================"
    echo ""
}

# --- Main --------------------------------------------------------------------

main() {
    local action="${1:-help}"

    case "$action" in
        setup)
            # Usage: ./client.sh setup <server-pubkey> <server-endpoint> [client-ip] [full|split]
            if [[ $# -lt 3 ]]; then
                error "Usage: $0 setup <server-public-key> <server-endpoint:port> [client-vpn-ip] [full|split]

  Example:
    $0 setup abc123pubkey== 203.0.113.1:51820
    $0 setup abc123pubkey== 203.0.113.1:51820 10.0.0.3/24 split"
            fi

            detect_os
            check_wireguard
            generate_keys
            create_client_config "$2" "$3" "${4:-$DEFAULT_CLIENT_IP}" "${5:-full}"

            echo ""
            echo "========================================"
            echo "  Client configured!"
            echo "========================================"
            echo ""
            echo "  Your public key: $CLIENT_PUBLIC_KEY"
            echo "  Your VPN IP:     ${4:-$DEFAULT_CLIENT_IP}"
            echo "  Server:          $3"
            echo ""
            echo "  Next steps:"
            echo "  1. Give your public key to the server admin"
            echo "  2. Run: ./client.sh connect"
            echo ""
            echo "========================================"
            ;;
        connect)
            detect_os
            connect
            ;;
        disconnect)
            detect_os
            disconnect
            ;;
        status)
            detect_os
            show_status
            ;;
        keys)
            detect_os
            check_wireguard
            generate_keys
            ;;
        *)
            echo "Usage: $0 {setup|connect|disconnect|status|keys}"
            echo ""
            echo "  setup <server-pubkey> <endpoint:port> [vpn-ip] [full|split]"
            echo "       Configure this machine as a VPN client"
            echo ""
            echo "  connect        Connect to the VPN"
            echo "  disconnect     Disconnect from the VPN"
            echo "  status         Show connection status"
            echo "  keys           Generate/show client keys"
            exit 1
            ;;
    esac
}

main "$@"
