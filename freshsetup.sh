#!/usr/bin/env bash
set -euo pipefail

# ========================
# freshsetup.sh
# ========================
# Performs:
# 1) Download + install Retropie shutdown script from ZIP
# 2) Enable root login over SSH, set root password to 'root'
# 3) Write NetworkManager wifi profiles with static IPv4
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

# SSHD config (exact content you pasted)
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
X11Forwarding yes
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

# First NetworkManager profile (with WAGSD3 suffix)
read -r -d '' NM_CONTENT_A <<"EOF"
[connection]
id=preconfigured
uuid=0bf0601a-749f-4c2c-893c-7ba5a9758d08
type=wifi
timestamp=1747095304

[wifi]
hidden=true
mode=infrastructure
ssid=Raspbain

[wifi-security]
key-mgmt=wpa-psk
psk=8cf640ea74906b5b7b4df01089861285e86fe325a65634395b0d99b22daf3ed9

[ipv4]
address1=192.168.0.140/24,192.168.0.1
dns=192.168.0.1;
method=manual

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
EOF

# Second NetworkManager profile (without suffix)
read -r -d '' NM_CONTENT_B <<"EOF"
[connection]
id=preconfigured
uuid=0bf0601a-749f-4c2c-893c-7ba5a9758d08
type=wifi
timestamp=1758798433

[wifi]
hidden=true
mode=infrastructure
ssid=Raspbain

[wifi-security]
key-mgmt=wpa-psk
psk=8cf640ea74906b5b7b4df01089861285e86fe325a65634395b0d99b22daf3ed9

[ipv4]
address1=192.168.0.140/24,192.168.0.1
dns=192.168.0.1;
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

# ---- run ----
require_root
require_cmd wget
require_cmd unzip
require_cmd passwd || true   # usually present
require_cmd chpasswd

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

echo "[4/5] Configuring SSH for root login and setting password..."
backup_file "$SSH_CONFIG_PATH"
printf "%s\n" "$SSHD_CONFIG_CONTENT" > "$SSH_CONFIG_PATH"

# Set root password to 'root'
echo "root:root" | chpasswd

restart_ssh

echo "[5/5] Writing NetworkManager profiles..."
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
echo " - Root SSH login is enabled. Password is 'root' (CHANGE THIS IMMEDIATELY)."
echo " - SSH service restarted."
echo " - NetworkManager profiles written to:"
echo "     $NM_FILE_A"
echo "     $NM_FILE_B"
echo " - If Wi-Fi doesn't come up automatically, try: nmcli con up preconfigured"
