#!/usr/bin/env bash
set -euo pipefail

# ========================
# freshsetup.sh
# ========================
# Performs:
# 1) Download + install Retropie shutdown script from ZIP
# 2) Enable root login over SSH
# 3) PROMPT for root password (no hardcoded default)
# 4) PROMPT for NetworkManager IPv4 address/gateway/DNS and write wifi profiles
#
# Tested for Debian/Raspberry Pi OS–style systems.
# Run as root:  sudo ./freshsetup.sh

# ---- Config you provided ----
REPO_ZIP_URL="https://github.com/AirysDark/Retropie-shutdown-sccript/archive/refs/heads/main.zip"
REPO_ZIP_NAME="main.zip"
REPO_DIR_NAME="Retropie-shutdown-sccript-main"   # matches GitHub ZIP folder
SSH_CONFIG_PATH="/etc/ssh/sshd_config"
NM_DIR="/etc/NetworkManager/system-connections"
NM_FILE_A="${NM_DIR}/preconfigured.nmconnection.WAGSD3"
NM_FILE_B="${NM_DIR}/preconfigured.nmconnection"

SSID_VALUE="Raspbain"
PSK_VALUE="8cf640ea74906b5b7b4df01089861285e86fe325a65634395b0d99b22daf3ed9"
UUID_VALUE="0bf0601a-749f-4c2c-893c-7ba5a9758d08"

# SSHD config (exact content you supplied, with PermitRootLogin yes)
read -r -d '' SSHD_CONFIG_CONTENT <<"EOF"
# This is the sshd server system-wide configuration file.  See
# sshd_config(5) for more information.

# This sshd was compiled with PATH=/usr/local/bin:/usr/bin:/bin:/usr/games

# The strategy used for options in the default sshd_config shipped with
# OpenSSH is to specify options with their default value where
# possible, but leave them commented.  Uncommented options override the
# default value.

Include /etc/ssh/sshd_config.d/*.conf

#Port 22
#AddressFamily any
#ListenAddress 0.0.0.0
#ListenAddress ::

#HostKey /etc/ssh/ssh_host_rsa_key
#HostKey /etc/ssh/ssh_host_ecdsa_key
#HostKey /etc/ssh/ssh_host_ed25519_key

# Ciphers and keying
#RekeyLimit default none

# Logging
#SyslogFacility AUTH
#LogLevel INFO

# Authentication:

#LoginGraceTime 2m
PermitRootLogin yes
#StrictModes yes
#MaxAuthTries 6
#MaxSessions 10

#PubkeyAuthentication yes

# Expect .ssh/authorized_keys2 to be disregarded by default in future.
#AuthorizedKeysFile	.ssh/authorized_keys .ssh/authorized_keys2

#AuthorizedPrincipalsFile none

#AuthorizedKeysCommand none
#AuthorizedKeysCommandUser nobody

# For this to work you will also need host keys in /etc/ssh/ssh_known_hosts
#HostbasedAuthentication no
# Change to yes if you don't trust ~/.ssh/known_hosts for
# HostbasedAuthentication
#IgnoreUserKnownHosts no
# Don't read the user's ~/.rhosts and ~/.shosts files
#IgnoreRhosts yes

# To disable tunneled clear text passwords, change to no here!
#PasswordAuthentication yes
#PermitEmptyPasswords no

# Change to yes to enable challenge-response passwords (beware issues with
# some PAM modules and threads)
KbdInteractiveAuthentication no

# Kerberos options
#KerberosAuthentication no
#KerberosOrLocalPasswd yes
#KerberosTicketCleanup yes
#KerberosGetAFSToken no

# GSSAPI options
#GSSAPIAuthentication no
#GSSAPICleanupCredentials yes
#GSSAPIStrictAcceptorCheck yes
#GSSAPIKeyExchange no

# Set this to 'yes' to enable PAM authentication, account processing,
# and session processing. If this is enabled, PAM authentication will
# be allowed through the KbdInteractiveAuthentication and
# PasswordAuthentication.  Depending on your PAM configuration,
# PAM authentication via KbdInteractiveAuthentication may bypass
# the setting of "PermitRootLogin prohibit-password".
# If you just want the PAM account and session checks to run without
# PAM authentication, then enable this but set PasswordAuthentication
# and KbdInteractiveAuthentication to 'no'.
UsePAM yes

#AllowAgentForwarding yes
#AllowTcpForwarding yes
#GatewayPorts no
X1Forwarding yes
#X11DisplayOffset 10
#X11UseLocalhost yes
#PermitTTY yes
PrintMotd no
#PrintLastLog yes
#TCPKeepAlive yes
#PermitUserEnvironment no
#Compression delayed
#ClientAliveInterval 0
#ClientAliveCountMax 3
#UseDNS no
#PidFile /run/sshd.pid
#MaxStartups 10:30:100
#PermitTunnel no
#ChrootDirectory none
#VersionAddendum none

# no default banner path
#Banner none

# Allow client to pass locale environment variables
AcceptEnv LANG LC_*

# override default of no subsystems
Subsystem	sftp	/usr/lib/openssh/sftp-server

# Example of overriding settings on a per-user basis
#Match User anoncvs
#	X11Forwarding no
#	AllowTcpForwarding no
#	PermitTTY no
#	ForceCommand cvs server
EOF

# NetworkManager profile templates (use placeholders, replace after prompts)
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

# Second file uses a different timestamp but same fields
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
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root (sudo ./freshsetup.sh)"; exit 1
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Installing missing dependency: $1"
    apt-get update -y
    apt-get install -y "$1"
  }
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

restart_ssh() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  fi
}

reload_nm() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload NetworkManager 2>/dev/null || true
  fi
  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection reload || true
  fi
}

prompt_nonempty() {
  local prompt="$1"
  local var
  while true; do
    read -r -p "$prompt" var
    if [[ -n "${var}" ]]; then
      echo "$var"
      return 0
    fi
    echo "Value cannot be empty."
  done
}

# ---- run ----
require_root
require_cmd wget
require_cmd unzip
require_cmd chpasswd

echo "================ Setup: Retropie shutdown script ================"
TMPDIR="$(mktemp -d)"
pushd "$TMPDIR" >/dev/null

echo "[1/5] Downloading repo ZIP..."
wget -O "$REPO_ZIP_NAME" "$REPO_ZIP_URL"

echo "[2/5] Unzipping..."
unzip -o "$REPO_ZIP_NAME"

echo "[3/5] Running install.sh retropie..."
pushd "$REPO_DIR_NAME" >/dev/null
sh install.sh retropie
popd >/dev/null

echo "================ SSH configuration =============================="
echo "[4/5] Configuring SSH for root login..."
backup_file "$SSH_CONFIG_PATH"
printf "%s\n" "$SSHD_CONFIG_CONTENT" > "$SSH_CONFIG_PATH"

# Prompt for root password (no echo)
echo "[*] Set root password (input hidden)."
while true; do
  read -s -p "Enter new root password: " ROOTPASS
  echo
  read -s -p "Confirm root password: " ROOTPASS2
  echo
  if [[ "$ROOTPASS" == "$ROOTPASS2" && -n "$ROOTPASS" ]]; then
    echo "root:$ROOTPASS" | chpasswd
    echo "[OK] Root password updated."
    break
  else
    echo "Passwords do not match or are empty. Try again."
  fi
done

restart_ssh
echo "[OK] SSH reloaded."

echo "================ NetworkManager profiles ========================"
echo "[5/5] Provide static IPv4 settings for Wi-Fi profile 'preconfigured'."
IPV4_ADDR=$(prompt_nonempty "IPv4 address with CIDR (e.g. 192.168.0.140/24): ")
IPV4_GW=$(prompt_nonempty   "Gateway (e.g. 192.168.0.1): ")
IPV4_DNS=$(prompt_nonempty  "DNS server (e.g. 192.168.0.1): ")

# Build profile contents from templates
NM_CONTENT_A="$NM_TEMPLATE"
NM_CONTENT_A="${NM_CONTENT_A//UUID_PLACEHOLDER/$UUID_VALUE}"
NM_CONTENT_A="${NM_CONTENT_A//SSID_PLACEHOLDER/$SSID_VALUE}"
NM_CONTENT_A="${NM_CONTENT_A//PSK_PLACEHOLDER/$PSK_VALUE}"
NM_CONTENT_A="${NM_CONTENT_A//IPV4_ADDR_PLACEHOLDER/$IPV4_ADDR}"
NM_CONTENT_A="${NM_CONTENT_A//IPV4_GW_PLACEHOLDER/$IPV4_GW}"
NM_CONTENT_A="${NM_CONTENT_A//IPV4_DNS_PLACEHOLDER/$IPV4_DNS}"

NM_CONTENT_B="$NM_TEMPLATE_B"
NM_CONTENT_B="${NM_CONTENT_B//UUID_PLACEHOLDER/$UUID_VALUE}"
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

popd >/dev/null
rm -rf "$TMPDIR"

echo "✅ Done."
echo "Notes:"
echo " - Root SSH login is ENABLED. Keep the password secret and consider disabling root SSH after setup."
echo " - NetworkManager profiles written to:"
echo "     $NM_FILE_A"
echo "     $NM_FILE_B"
echo " - Bring Wi-Fi up (if not automatic): nmcli con up preconfigured"
