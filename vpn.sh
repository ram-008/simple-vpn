#!/usr/bin/env bash
# =============================================================================
# vpn.sh — Simple VPN CLI (WireGuard)
# =============================================================================
# A terminal-based tool to set up and manage a WireGuard VPN.
#
# This is the main entry point that dispatches to server.sh and client.sh.
# Run ./vpn.sh with no arguments to see usage.
#
# Quick start:
#   On your server:   sudo ./vpn.sh server-setup
#   On your client:   ./vpn.sh client-setup <server-pubkey> <server-ip:port>
#   Connect:          ./vpn.sh connect
#   Disconnect:       ./vpn.sh disconnect
# =============================================================================

set -euo pipefail

# --- Constants ---------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.0.0"

# --- Colors ------------------------------------------------------------------

BOLD="\033[1m"
BLUE="\033[1;34m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

# --- Helper Functions --------------------------------------------------------

info()  { echo -e "${BLUE}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# --- Dependency Check --------------------------------------------------------

check_dependencies() {
    local missing=0

    if ! command -v wg &>/dev/null; then
        echo -e "${RED}Missing: wireguard-tools${RESET}"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Install WireGuard tools:"
        echo ""
        case "$(uname -s)" in
            Linux*)
                echo "  Ubuntu/Debian:  sudo apt install wireguard"
                echo "  Fedora:         sudo dnf install wireguard-tools"
                echo "  Arch:           sudo pacman -S wireguard-tools"
                ;;
            Darwin*)
                echo "  macOS:          brew install wireguard-tools"
                ;;
        esac
        echo ""
        exit 1
    fi
}

# --- Usage / Help ------------------------------------------------------------

show_help() {
    cat <<EOF

${BOLD}simple-vpn${RESET} v${VERSION} — WireGuard VPN from the terminal

${BOLD}USAGE${RESET}
    ./vpn.sh <command> [options]

${BOLD}SERVER COMMANDS${RESET}  (run on the VPN server)
    ${GREEN}server-setup${RESET}                       Set up this machine as a VPN server
    ${GREEN}add-peer${RESET} <client-pubkey> <vpn-ip>   Add a client to the server
    ${GREEN}server-status${RESET}                      Show server status

${BOLD}CLIENT COMMANDS${RESET}  (run on the VPN client)
    ${GREEN}client-setup${RESET} <server-pubkey> <endpoint:port> [vpn-ip] [full|split]
                                        Configure this machine as a VPN client
    ${GREEN}connect${RESET}                            Connect to the VPN
    ${GREEN}disconnect${RESET}                         Disconnect from the VPN
    ${GREEN}status${RESET}                             Show connection status
    ${GREEN}keys${RESET}                               Generate or show client keys

${BOLD}OTHER${RESET}
    ${GREEN}help${RESET}                               Show this help message
    ${GREEN}version${RESET}                            Show version

${BOLD}EXAMPLES${RESET}
    # Set up VPN server (on your server machine):
    sudo ./vpn.sh server-setup

    # Set up client and connect (on your laptop/desktop):
    ./vpn.sh client-setup AbC123ServerPubKey== 203.0.113.1:51820
    ./vpn.sh connect

    # Full tunnel (all traffic through VPN):
    ./vpn.sh client-setup AbC123ServerPubKey== 203.0.113.1:51820 10.0.0.2/24 full

    # Split tunnel (only VPN network traffic):
    ./vpn.sh client-setup AbC123ServerPubKey== 203.0.113.1:51820 10.0.0.2/24 split

    # Add a second client on the server:
    sudo ./vpn.sh add-peer XyZ789ClientPubKey== 10.0.0.3

${BOLD}HOW IT WORKS${RESET}
    WireGuard creates an encrypted UDP tunnel between peers. Each peer has a
    cryptographic keypair. Traffic is encrypted with ChaCha20-Poly1305 and
    key exchange uses Curve25519. It's fast, modern, and auditable (~4000
    lines of code in the kernel module).

    See README.md for a detailed explanation.

EOF
}

# --- Command Dispatch --------------------------------------------------------

main() {
    local command="${1:-help}"

    case "$command" in
        # --- Server commands ---
        server-setup)
            check_dependencies
            bash "$SCRIPT_DIR/server.sh" setup
            ;;
        add-peer)
            check_dependencies
            shift
            bash "$SCRIPT_DIR/server.sh" add-peer "$@"
            ;;
        server-status)
            bash "$SCRIPT_DIR/server.sh" status
            ;;

        # --- Client commands ---
        client-setup)
            check_dependencies
            shift
            bash "$SCRIPT_DIR/client.sh" setup "$@"
            ;;
        connect)
            check_dependencies
            bash "$SCRIPT_DIR/client.sh" connect
            ;;
        disconnect)
            bash "$SCRIPT_DIR/client.sh" disconnect
            ;;
        status)
            bash "$SCRIPT_DIR/client.sh" status
            ;;
        keys)
            check_dependencies
            bash "$SCRIPT_DIR/client.sh" keys
            ;;

        # --- Other ---
        help|--help|-h)
            show_help
            ;;
        version|--version|-v)
            echo "simple-vpn v${VERSION}"
            ;;
        *)
            echo -e "${RED}Unknown command: $command${RESET}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
