#!/usr/bin/env bash
set -euo pipefail

# ========================
# freshsetup.sh
# ========================
# Performs:
# 1) Enable root login over SSH
# 2) PROMPT for root password (no hardcoded default)
# 3) PROMPT for NetworkManager IPv4 address/gateway/DNS and write wifi profiles
# 4) Download + install Retropie shutdown script
# 5) Auto reboot
#
# Tested for Debian/Raspberry Pi OS–style systems.
# Run as root:  sudo ./freshsetup.sh

REPO_ZIP_URL="https://github.com/AirysDark/Retropie-shutdown-sccript/archive/refs/heads/main.zip"
REPO_ZIP_NAME="main.zip"
REPO_DIR_NAME="Retropie-shutdown-sccript-main"
SSH_CONFIG_PATH="/etc/ssh/sshd_config"
NM_DIR="/etc/NetworkManager/system-connections"
NM_FILE_A="${NM_DIR}/preconfigured.nmconnection.WAGSD3"
NM_FILE_B="${NM_DIR}/preconfigured.nmconnection"

SSID_VALUE="Raspbain"
PSK_VALUE="8cf640ea74906b5b7b4df01089861285e86fe325a65634395b0d99b22daf3ed9"
UUID_VALUE="0bf0601a-749f-4c2c-893c-7ba5a9758d08"

# SSHD config
read -r -d '' SSHD_CONFIG_CONTENT <<"EOF"
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# NetworkManager profile templates
read -r -d '' NM_TEMPLATE <<"EOF"
[connection]
id=preconfigured
uuid=UUID_PLACEHOLDER
type=wifi
timestamp=1747095304

[wifi]
hidden=true
mode=infrastructure
ssid=SSID_PLACEHOLDER

[wifi-security]
key-mgmt=wpa-psk
psk=PSK_PLACEHOLDER

[ipv4]
address1=IPV4_ADDR_PLACEHOLDER,IPV4_GW_PLACEHOLDER
dns=IPV4_DNS_PLACEHOLDER;
method=manual

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
EOF

read -r -d '' NM_TEMPLATE_B <<"EOF"
[connection]
id=preconfigured
uuid=UUID_PLACEHOLDER
type=wifi
timestamp=1758798433

[wifi]
hidden=true
mode=infrastructure
ssid=SSID_PLACEHOLDER

[wifi-security]
key-mgmt=wpa-psk
psk=PSK_PLACEHOLDER

[ipv4]
address1=IPV4_ADDR_PLACEHOLDER,IPV4_GW_PLACEHOLDER
dns=IPV4_DNS_PLACEHOLDER;
method=manual

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
EOF

# ---- helpers ----
require_root() { [[ "${EUID}" -eq 0 ]] || { echo "Run as root"; exit 1; }; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { apt-get update -y; apt-get install -y "$1"; }; }
backup_file() { [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; }
restart_ssh() { systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true; }
reload_nm() { systemctl reload NetworkManager 2>/dev/null || true; nmcli connection reload || true; }
prompt_nonempty() { local var; while true; do read -r -p "$1" var; [[ -n "$var" ]] && { echo "$var"; return; }; done; }

# ---- run ----
require_root
require_cmd wget
require_cmd unzip
require_cmd chpasswd

echo "================ SSH configuration =============================="
backup_file "$SSH_CONFIG_PATH"
printf "%s\n" "$SSHD_CONFIG_CONTENT" > "$SSH_CONFIG_PATH"

# Prompt for root password
echo "[*] Set root password (input hidden)."
while true; do
  read -s -p "Enter new root password: " ROOTPASS; echo
  read -s -p "Confirm root password: " ROOTPASS2; echo
  if [[ "$ROOTPASS" == "$ROOTPASS2" && -n "$ROOTPASS" ]]; then
    echo "root:$ROOTPASS" | chpasswd
    echo "[OK] Root password updated."
    break
  else
    echo "Passwords do not match or are empty. Try again."
  fi
done

restart_ssh
echo "[OK] SSH restarted."

echo "================ NetworkManager profiles ========================"
IPV4_ADDR=$(prompt_nonempty "IPv4 address with CIDR (e.g. 192.168.0.140/24): ")
IPV4_GW=$(prompt_nonempty   "Gateway (e.g. 192.168.0.1): ")
IPV4_DNS=$(prompt_nonempty  "DNS server (e.g. 192.168.0.1): ")

NM_CONTENT_A="${NM_TEMPLATE//UUID_PLACEHOLDER/$UUID_VALUE}"
NM_CONTENT_A="${NM_CONTENT_A//SSID_PLACEHOLDER/$SSID_VALUE}"
NM_CONTENT_A="${NM_CONTENT_A//PSK_PLACEHOLDER/$PSK_VALUE}"
NM_CONTENT_A="${NM_CONTENT_A//IPV4_ADDR_PLACEHOLDER/$IPV4_ADDR}"
NM_CONTENT_A="${NM_CONTENT_A//IPV4_GW_PLACEHOLDER/$IPV4_GW}"
NM_CONTENT_A="${NM_CONTENT_A//IPV4_DNS_PLACEHOLDER/$IPV4_DNS}"

NM_CONTENT_B="${NM_TEMPLATE_B//UUID_PLACEHOLDER/$UUID_VALUE}"
NM_CONTENT_B="${NM_CONTENT_B//SSID_PLACEHOLDER/$SSID_VALUE}"
NM_CONTENT_B="${NM_CONTENT_B//PSK_PLACEHOLDER/$PSK_VALUE}"
NM_CONTENT_B="${NM_CONTENT_B//IPV4_ADDR_PLACEHOLDER/$IPV4_ADDR}"
NM_CONTENT_B="${NM_CONTENT_B//IPV4_GW_PLACEHOLDER/$IPV4_GW}"
NM_CONTENT_B="${NM_CONTENT_B//IPV4_DNS_PLACEHOLDER/$IPV4_DNS}"

mkdir -p "$NM_DIR"
printf "%s\n" "$NM_CONTENT_A" > "$NM_FILE_A"
printf "%s\n" "$NM_CONTENT_B" > "$NM_FILE_B"
chown root:root "$NM_FILE_A" "$NM_FILE_B"
chmod 600 "$NM_FILE_A" "$NM_FILE_B"

reload_nm
echo "[OK] Network profiles written."

echo "================ Retropie shutdown script ======================="
TMPDIR2="$(mktemp -d)"
pushd "$TMPDIR2" >/dev/null
wget -O "$REPO_ZIP_NAME" "$REPO_ZIP_URL"
unzip -o "$REPO_ZIP_NAME"
cd "$REPO_DIR_NAME"
sh install.sh retropie
popd >/dev/null
rm -rf "$TMPDIR2"

echo "================ Rebooting now ================================"
reboot || shutdown -r now
