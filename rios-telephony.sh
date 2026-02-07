#!/usr/bin/env bash

# ============================================================================
# RIOS Telephony Bridge - Proxmox LXC Creation Script
# ============================================================================
# Creates an LXC container with FreeSWITCH + mod_audio_stream + Node.js bridge
# for RIOS AI telephony integration via 3CX SBC.
#
# Usage (run on Proxmox host):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_REPO/main/ct/rios-telephony.sh)"
#
# Based on: https://github.com/asylumexp/Proxmox patterns
# ============================================================================

APP="RIOS-Telephony"
var_tags="${var_tags:-telephony;freeswitch;rios}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

# Colors
BL='\033[36m'  # Cyan
GN='\033[32m'  # Green
RD='\033[31m'  # Red
YW='\033[33m'  # Yellow
CL='\033[0m'   # Clear

# Helper functions
msg_info() { echo -e "${BL}[INFO]${CL} $1"; }
msg_ok() { echo -e "${GN}[OK]${CL} $1"; }
msg_error() { echo -e "${RD}[ERROR]${CL} $1"; }

header_info() {
  clear
  cat <<"EOF"
    ____  ________  _____
   / __ \/  _/ __ \/ ___/
  / /_/ // // / / /\__ \   Telephony Bridge
 / _, _// // /_/ /___/ /   FreeSWITCH + Gemini Live
/_/ |_/___/\____//____/    LXC Installer

EOF
  echo -e "${BL}Creating LXC container for RIOS Telephony Bridge${CL}"
  echo ""
}

# ============================================================================
# MAIN
# ============================================================================
header_info

# Check we're running on Proxmox
if ! command -v pct &>/dev/null; then
  msg_error "This script must be run on a Proxmox VE host."
  exit 1
fi

echo -e "${YW}This will create a Debian 12 LXC container with:${CL}"
echo "  - FreeSWITCH (compiled from source)"
echo "  - mod_audio_stream (WebSocket audio streaming)"
echo "  - Node.js 20 LTS (RIOS telephony bridge)"
echo "  - Configured to register as SIP extension on your 3CX"
echo ""

# Prompt for settings
read -r -p "Enter Container ID [default: 300]: " CT_ID
CT_ID=${CT_ID:-300}

read -r -p "Enter Hostname [default: rios-telephony]: " CT_HOSTNAME
CT_HOSTNAME=${CT_HOSTNAME:-rios-telephony}

read -r -p "Enter CPU cores [default: ${var_cpu}]: " CT_CPU
CT_CPU=${CT_CPU:-$var_cpu}

read -r -p "Enter RAM in MB [default: ${var_ram}]: " CT_RAM
CT_RAM=${CT_RAM:-$var_ram}

read -r -p "Enter Disk size in GB [default: ${var_disk}]: " CT_DISK
CT_DISK=${CT_DISK:-$var_disk}

# Storage selection
STORAGE_LIST=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}')
if [ -z "$STORAGE_LIST" ]; then
  msg_error "No storage found for rootdir content. Please configure storage first."
  exit 1
fi

echo ""
echo -e "${YW}Available storage:${CL}"
echo "$STORAGE_LIST"
read -r -p "Enter storage name [default: local-lvm]: " CT_STORAGE
CT_STORAGE=${CT_STORAGE:-local-lvm}

# Network config
read -r -p "Use DHCP? (y/n) [default: y]: " USE_DHCP
USE_DHCP=${USE_DHCP:-y}

# Ask whether user plans to use a 3CX SBC on the LAN
read -r -p "Will you use a 3CX SBC on your LAN? (y/n) [default: n]: " USE_SBC
USE_SBC=${USE_SBC:-n}

if [[ "${USE_DHCP,,}" == "n" ]]; then
  read -r -p "Enter static IP (e.g., 192.168.1.50/24): " CT_IP
  read -r -p "Enter gateway (e.g., 192.168.1.1): " CT_GW
  NET_CONFIG="name=eth0,bridge=vmbr0,ip=${CT_IP},gw=${CT_GW}"
else
  NET_CONFIG="name=eth0,bridge=vmbr0,ip=dhcp"
  # If DHCP but SBC will be used, offer to set a static IP (recommended for stable SBC mapping)
  if [[ "${USE_SBC,,}" == "y" ]]; then
    read -r -p "You selected DHCP but indicated you'll use an SBC — set a static IP for the LXC? (y/n) [default: y]: " SET_STATIC_FOR_SBC
    SET_STATIC_FOR_SBC=${SET_STATIC_FOR_SBC:-y}
    if [[ "${SET_STATIC_FOR_SBC,,}" == "y" ]]; then
      read -r -p "Enter static IP (e.g., 192.168.1.50/24): " CT_IP
      read -r -p "Enter gateway (e.g., 192.168.1.1): " CT_GW
      NET_CONFIG="name=eth0,bridge=vmbr0,ip=${CT_IP},gw=${CT_GW}"
    fi
  fi
fi

# If using an SBC, optionally collect the SBC host/IP for convenience in the summary
if [[ "${USE_SBC,,}" == "y" ]]; then
  read -r -p "Enter SBC IP or hostname (optional, press Enter to skip): " SBC_HOST
fi

# Download template if needed
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"

# Check architecture
ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
if [[ "$ARCH" == "arm64" ]]; then
  TEMPLATE="debian-12-standard_12.7-1_arm64.tar.zst"
  TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"
fi

if [ ! -f "$TEMPLATE_PATH" ]; then
  msg_info "Downloading Debian 12 template..."
  pveam update
  pveam download local "$TEMPLATE" || {
    msg_error "Failed to download template. Please download it manually."
    exit 1
  }
fi

msg_info "Creating LXC container ${CT_ID} (${CT_HOSTNAME})..."

pct create "$CT_ID" "local:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CT_CPU" \
  --memory "$CT_RAM" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "$NET_CONFIG" \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 0 || {
    msg_error "Failed to create container"
    exit 1
  }

msg_ok "Container ${CT_ID} created"

# Start container
msg_info "Starting container..."
pct start "$CT_ID"
sleep 5
msg_ok "Container started"

# Push install script into container and execute
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/Caspia-n/collection/refs/heads/main/rios-telephony-install.sh"

msg_info "Running installation inside container..."

# Copy the install script - for local use, we embed it
pct exec "$CT_ID" -- bash -c "
  apt-get update && apt-get install -y curl
  # The install script can be fetched from repo or we run it inline
  curl -fsSL '${INSTALL_SCRIPT_URL}' -o /tmp/install.sh 2>/dev/null || true
  if [ -f /tmp/install.sh ]; then
    bash /tmp/install.sh
  else
    echo 'Install script not found at URL. Please run the install script manually inside the container.'
    echo 'pct enter ${CT_ID}'
    echo 'Then run: bash /path/to/install/rios-telephony-install.sh'
  fi
"

# Get container IP
sleep 3
CT_IP_ADDR=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

echo ""
msg_ok "RIOS Telephony Bridge LXC container created!"
echo ""
echo -e "${GN}Container ID:${CL}    ${CT_ID}"
echo -e "${GN}Hostname:${CL}        ${CT_HOSTNAME}"
echo -e "${GN}IP Address:${CL}      ${CT_IP_ADDR:-pending DHCP}"
echo -e "${GN}CPU:${CL}             ${CT_CPU} cores"
echo -e "${GN}RAM:${CL}             ${CT_RAM} MB"
echo -e "${GN}Disk:${CL}            ${CT_DISK} GB"
# Show SBC information if provided
echo -e "${GN}Using SBC:${CL}       ${USE_SBC:-n}"
if [ -n "${SBC_HOST:-}" ]; then
  echo -e "${GN}SBC Host:${CL}        ${SBC_HOST}"
fi
echo ""
echo -e "${YW}Next steps:${CL}"
echo "  1. Enter container:  pct enter ${CT_ID}"
echo "  2. Run install:      bash /opt/rios-telephony/install.sh"
echo "  3. Configure:        nano /opt/rios-telephony/bridge/.env"
echo "  4. Set 3CX SIP:      See /opt/rios-telephony/3CX-SETUP.md"
# If SBC is used, add a brief note to the next steps
if [[ "${USE_SBC,,}" == "y" ]]; then
  echo "  5. SBC note:         If you installed or will use an SBC, update the FreeSWITCH gateway to point at the SBC IP (see 3CX-SETUP.md)"
fi
echo ""
