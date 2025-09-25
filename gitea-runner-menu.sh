#!/usr/bin/env bash
# gitea-runner-menu.sh
# All-in-one menu:
#  - First install: configure Gitea (+install if missing) → generate token (CLI) → install runner
#  - Gitea: install if missing, enable Actions, set ROOT_URL, restart, optional token generation
#  - Runner: install if missing (interactive) OR re-register existing
#  - Fresh OS: root SSH enable + root password prompt + NM Wi-Fi profiles (5 manual inputs) + RetroPie shutdown script (auto "No") + final summary + reboot
#  - Ops tools: reconfigure/update runner, status, logs, network checks
# Raspberry Pi OS / Debian-friendly (ARM64). Run as a regular user with sudo available.

set -euo pipefail

# ===================== Session Prefill =====================
PREFILL_INSTANCE_URL=""
PREFILL_TOKEN=""

# ===================== Helpers =====================
ask() {
  local prompt="${1:-}" default="${2-}" reply
  if [[ -n "${default}" ]]; then
    read -rp "$prompt [$default]: " reply || true
    echo "${reply:-$default}"
  else
    read -rp "$prompt: " reply || true
    echo "${reply}"
  fi
}
prompt_nonempty() {
  local prompt="${1:-}" val=""
  while true; do
    read -rp "$prompt" val || true
    [[ -n "$val" ]] && { echo "$val"; return 0; }
    echo "Value cannot be empty."
  done
}
pause() { read -rp "Press Enter to continue..." || true; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
status_ok()   { echo -e "\e[32m$*\e[0m"; }
status_info() { echo -e "\e[36m$*\e[0m"; }
status_warn() { echo -e "\e[33m$*\e[0m"; }
status_err()  { echo -e "\e[31m$*\e[0m"; }
print_hr()    { printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '-'; }

_systemctl() { (sudo systemctl "$@" 2>/dev/null) || (systemctl --user "$@" 2>/dev/null || true); }
_systemctl_status() { _systemctl status "$@" --no-pager || true; }
_journal_tail() { (sudo journalctl -u "$1" -n "${2:-200}" --no-pager 2>/dev/null) || true; }

# ===================== Gitea Bootstrap Install (if missing) =====================
gitea_bootstrap_install() {
  status_warn "Gitea not found. Installing Gitea and prerequisites..."
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y git build-essential sqlite3 nginx fcgiwrap wget curl

  if ! have_cmd gitea; then
    status_info "Downloading Gitea 1.21.11 (arm64)..."
    wget -O gitea https://dl.gitea.io/gitea/1.21.11/gitea-1.21.11-linux-arm64
    chmod +x gitea
    sudo mv gitea /usr/local/bin/
  fi

  if ! id -u git >/dev/null 2>&1; then
    sudo adduser --system --group --disabled-password --home /home/git git
  fi

  sudo mkdir -p /var/lib/gitea/{custom,data,log}
  sudo chown -R git:git /var/lib/gitea/
  sudo chmod -R 750 /var/lib/gitea/

  if [[ ! -f /etc/systemd/system/gitea.service ]]; then
    status_info "Writing systemd service /etc/systemd/system/gitea.service"
    sudo tee /etc/systemd/system/gitea.service >/dev/null <<'EOF'
[Unit]
Description=Gitea (GitHub clone)
After=network.target

[Service]
RestartSec=2s
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /var/lib/gitea/custom/conf/app.ini
Restart=always
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea/

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reexec
    sudo systemctl enable gitea
  fi

  sudo systemctl start gitea || true
  status_ok "Gitea installed ✅  Visit: http://<your-raspi-ip>:3000"
}

# ===================== Token Generation via Gitea CLI =====================
REG_TOKEN_OUT=""
gitea_generate_token_cli() {
  local cfg_path="$1"
  REG_TOKEN_OUT=""
  if ! have_cmd gitea; then
    status_warn "Gitea CLI not on PATH; cannot auto-generate token."
    return 1
  fi
  status_info "Generating runner registration token via Gitea CLI..."
  if REG_TOKEN_OUT="$(sudo gitea --config "$cfg_path" actions generate-runner-token 2>/dev/null)"; then
    status_ok "Registration Token:"
    echo "$REG_TOKEN_OUT"
    return 0
  else
    status_err "Failed to generate token via CLI (binary/permissions?)."
    return 1
  fi
}

# ===================== Gitea Configure (enable Actions + ROOT_URL) =====================
gitea_server_flow() {
  print_hr
  echo "Gitea server setup (install if missing, enable Actions, set ROOT_URL, restart, optional token)"
  print_hr

  if ! have_cmd gitea; then
    gitea_bootstrap_install
  fi

  # Detect an existing config or default to /var/lib/gitea/custom/conf/app.ini
  local default_cfg=""
  if   [[ -f /etc/gitea/app.ini ]]; then default_cfg="/etc/gitea/app.ini"
  elif [[ -f /etc/gitea/conf/app.ini ]]; then default_cfg="/etc/gitea/conf/app.ini"
  elif [[ -f /var/lib/gitea/custom/conf/app.ini ]]; then default_cfg="/var/lib/gitea/custom/conf/app.ini"
  fi

  local cfg_path
  cfg_path="$(ask "Path to app.ini" "${default_cfg:-/var/lib/gitea/custom/conf/app.ini}")"
  sudo mkdir -p "$(dirname "$cfg_path")"
  sudo touch "$cfg_path"

  local ip port proto
  ip="$(ask "Gitea host/IP for ROOT_URL" "192.168.0.140")"
  port="$(ask "Gitea HTTP port" "3000")"
  proto="$(ask "Protocol" "http")"

  local root_url="${proto}://${ip}:${port}/"
  PREFILL_INSTANCE_URL="$root_url"

  status_info "Ensuring [server] and [actions] in ${cfg_path} ..."
  if ! sudo grep -q '^\[server\]' "$cfg_path"; then echo | sudo tee -a "$cfg_path" >/dev/null; echo "[server]" | sudo tee -a "$cfg_path" >/dev/null; fi
  if ! sudo grep -q '^\[actions\]' "$cfg_path"; then echo | sudo tee -a "$cfg_path" >/dev/null; echo "[actions]" | sudo tee -a "$cfg_path" >/dev/null; fi

  sudo awk -v root_url="$root_url" -v port="$port" '
    BEGIN{srv=0; act=0}
    /^\[server\]/{srv=1; act=0; print; next}
    /^\[actions\]/{srv=0; act=1; print; next}
    /^\[/{srv=0; act=0; print; next}
    {
      if(srv==1){
        if($0 ~ /^PROTOCOL[ \t]*=/){print "PROTOCOL = http"; next}
        if($0 ~ /^HTTP_ADDR[ \t]*=/){print "HTTP_ADDR = 0.0.0.0"; next}
        if($0 ~ /^HTTP_PORT[ \t]*=/){print "HTTP_PORT = " port; next}
        if($0 ~ /^ROOT_URL[ \t]*=/){print "ROOT_URL = " root_url; next}
      }
      if(act==1){
        if($0 ~ /^ENABLED[ \t]*=/){print "ENABLED = true"; next}
      }
      print
    }
  ' "$cfg_path" | sudo tee "${cfg_path}.tmp" >/dev/null

  sudo awk -v root_url="$root_url" -v port="$port" '
    BEGIN{srv=0;act=0;haveP=0;haveA=0;havePort=0;haveAddr=0;haveRoot=0;haveEnabled=0}
    {
      if($0 ~ /^\[server\]/){srv=1;act=0}
      else if($0 ~ /^\[actions\]/){srv=0;act=1}
      else if($0 ~ /^\[/){srv=0;act=0}
      if(srv==1){
        if($0 ~ /^PROTOCOL[ \t]*=/) haveP=1
        if($0 ~ /^HTTP_ADDR[ \t]*=/) haveAddr=1
        if($0 ~ /^HTTP_PORT[ \t]*=/) havePort=1
        if($0 ~ /^ROOT_URL[ \t]*=/) haveRoot=1
      }
      if(act==1){
        if($0 ~ /^ENABLED[ \t]*=/) haveEnabled=1
      }
      print
    }
    END{
      if(!haveP)    print "PROTOCOL = http"
      if(!haveAddr) print "HTTP_ADDR = 0.0.0.0"
      if(!havePort) print "HTTP_PORT = " port
      if(!haveRoot) print "ROOT_URL = " root_url
      if(!haveEnabled){ print ""; print "[actions]"; print "ENABLED = true" }
    }
  ' "${cfg_path}.tmp" | sudo tee "$cfg_path" >/dev/null
  sudo rm -f "${cfg_path}.tmp"

  status_info "Restarting Gitea ..."
  if have_cmd systemctl; then
    sudo systemctl restart gitea || status_warn "systemctl restart failed; start service manually if needed."
  fi

  status_info "Health check ${root_url} ..."
  if curl -sfL "${root_url}" -o /dev/null; then
    status_ok "Gitea OK ✅"
  else
    status_err "Gitea not reachable ❌ (firewall/ports/service logs?)"
  fi

  local do_gen
  do_gen="$(ask "Generate a runner registration token now (CLI)? (yes/no)" "yes")"
  if [[ "$do_gen" =~ ^y(es)?$ ]]; then
    if gitea_generate_token_cli "$cfg_path"; then
      PREFILL_TOKEN="$(echo "$REG_TOKEN_OUT" | tr -d '\r\n')"
      status_info "Saved token for this session."
    else
      status_warn "Could not generate token automatically. You can copy one from the Web UI."
    fi
  else
    status_info "Skipping auto token generation."
  fi

  pause
}

# ===================== Runner Install (if missing) =====================
runner_bootstrap_install_interactive() {
  print_hr
  echo "Runner not found — installing and registering act_runner"
  print_hr

  # ======== Interactive inputs ========
  local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS RUNNER_VERSION INSTALL_DIR SERVICE_USER
  INSTANCE_URL="$(ask "INSTANCE_URL" "${PREFILL_INSTANCE_URL:-http://192.168.0.140:3000/}")"
  REG_TOKEN="$(ask "Registration token" "${PREFILL_TOKEN:-}")"
  RUNNER_NAME="$(ask "Runner name" "runner")"
  RUNNER_LABELS="$(ask "Runner labels (comma-separated)" "self-hosted,linux,arm64,pi")"
  RUNNER_VERSION="$(ask "act_runner version" "0.2.10")"
  INSTALL_DIR="$(ask "Install dir for act_runner" "/usr/local/bin")"
  SERVICE_USER="$(ask "Systemd service user" "$USER")"

  if [[ -z "$REG_TOKEN" ]]; then
    status_err "REG_TOKEN is required to register the runner."
    return 1
  fi

  # ======== Install prerequisites ========
  status_info "Updating system & installing dependencies ..."
  sudo apt-get update -y
  sudo apt-get install -y curl unzip

  # ======== Install act_runner ========
  status_info "Installing act_runner ${RUNNER_VERSION} ..."
  curl -L "https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-arm64" -o /tmp/act_runner
  chmod +x /tmp/act_runner
  sudo mv /tmp/act_runner "${INSTALL_DIR}/act_runner"

  # ======== Register runner ========
  status_info "Registering runner ..."
  mkdir -p "$HOME/.config/act_runner"
  "${INSTALL_DIR}/act_runner" register \
    --instance "${INSTANCE_URL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}"

  # ======== Create systemd service ========
  status_info "Creating systemd service gitea-runner.service ..."
  sudo tee /etc/systemd/system/gitea-runner.service >/dev/null <<EOF
[Unit]
Description=Gitea Actions Runner
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=$HOME
Environment=XDG_CONFIG_HOME=$HOME/.config
WorkingDirectory=$HOME
ExecStart=${INSTALL_DIR}/act_runner daemon
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

  status_info "Enabling & starting service ..."
  sudo systemctl daemon-reload
  sudo systemctl enable gitea-runner
  sudo systemctl start gitea-runner

  status_ok "✅ Done! Runner installed and started."
  echo "Check logs:  journalctl -u gitea-runner -f"
  pause
}

runner_installed() {
  # Consider installed if act_runner exists OR a service exists/active
  if have_cmd act_runner; then return 0; fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^gitea-runner\.service'; then return 0; fi
  if systemctl is-active gitea-runner >/dev/null 2>&1; then return 0; fi
  return 1
}

# ===================== Runner Flow =====================
runner_flow() {
  print_hr
  echo "Runner install / register"
  print_hr

  if ! runner_installed; then
    runner_bootstrap_install_interactive
    print_hr
    status_info "Service status:"
    _systemctl_status gitea-runner
    echo
    status_info "Recent logs:"
    _journal_tail gitea-runner 200
    pause
    return 0
  fi

  status_ok "act_runner appears to be installed already."
  _systemctl_status gitea-runner
  echo

  local re_reg
  re_reg="$(ask "Re-register this runner with a new token/name/labels? (yes/no)" "no")"
  if [[ "$re_reg" =~ ^y(es)?$ ]]; then
    status_info "Stopping runner service ..."
    sudo systemctl stop gitea-runner || true
    status_info "Wiping previous runner config (~/.config/act_runner) ..."
    rm -rf "$HOME/.config/act_runner" 2>/dev/null || true

    local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS
    INSTANCE_URL="$(ask "INSTANCE_URL" "${PREFILL_INSTANCE_URL:-http://192.168.0.140:3000/}")"
    REG_TOKEN="$(ask "Registration token" "${PREFILL_TOKEN:-}")"
    RUNNER_NAME="$(ask "Runner name" "runner-pi")"
    RUNNER_LABELS="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"

    if [[ -z "$REG_TOKEN" ]]; then
      status_err "REG_TOKEN is required to register."
      pause; return 1
    fi

    status_info "Re-registering runner ..."
    act_runner register \
      --instance "${INSTANCE_URL}" \
      --token "${REG_TOKEN}" \
      --name "${RUNNER_NAME}" \
      --labels "${RUNNER_LABELS}"

    status_info "Starting runner service ..."
    sudo systemctl start gitea-runner || true
    status_ok "Re-registration complete ✅"
  fi

  echo
  status_info "Recent logs:"
  _journal_tail gitea-runner 200
  pause
}

# ===================== Fresh OS Setup (5 manual inputs + summary) =====================
fresh_os_flow() {
  print_hr
  echo "Fresh OS setup: enable root SSH, set root password,"
  echo "configure NetworkManager Wi-Fi (manual SSID/PSK/IP/GW/DNS),"
  echo "install RetroPie shutdown script (auto 'No'), then show summary and reboot."
  print_hr

  # Constants
  local REPO_ZIP_URL="https://github.com/AirysDark/Retropie-shutdown-sccript/archive/refs/heads/main.zip"
  local REPO_ZIP_NAME="main.zip"
  local REPO_DIR_NAME="Retropie-shutdown-sccript-main"
  local SSH_CONFIG_PATH="/etc/ssh/sshd_config"
  local NM_DIR="/etc/NetworkManager/system-connections"
  local NM_FILE_A="${NM_DIR}/preconfigured.nmconnection.WAGSD3"
  local NM_FILE_B="${NM_DIR}/preconfigured.nmconnection"
  local UUID_VALUE="0bf0601a-749f-4c2c-893c-7ba5a9758d08"

  # Templates
  read -r -d '' SSHD_CONFIG_CONTENT <<"EOFSSHD"
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOFSSHD

  read -r -d '' NM_TEMPLATE <<"EOFNM"
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
EOFNM

  read -r -d '' NM_TEMPLATE_B <<"EOFNM2"
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
EOFNM2

  # Ensure packages
  status_info "Installing prerequisites (wget, unzip, passwd, network-manager)..."
  sudo apt-get update -y
  sudo apt-get install -y wget unzip passwd network-manager

  # Enable root SSH
  status_info "Configuring SSHD to permit root login..."
  if [[ -f "$SSH_CONFIG_PATH" ]]; then
    sudo cp -a "$SSH_CONFIG_PATH" "$SSH_CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  fi
  echo "$SSHD_CONFIG_CONTENT" | sudo tee "$SSH_CONFIG_PATH" >/dev/null
  sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
  status_ok "[OK] SSH restarted."

  # Root password (hidden)
  status_info "Set root password (input hidden)."
  local ROOTPASS ROOTPASS2
  while true; do
    read -s -p "Enter new root password: " ROOTPASS; echo
    read -s -p "Confirm root password: " ROOTPASS2; echo
    if [[ "$ROOTPASS" == "$ROOTPASS2" && -n "$ROOTPASS" ]]; then
      echo "root:$ROOTPASS" | sudo chpasswd
      status_ok "[OK] Root password updated."
      break
    else
      status_err "Passwords do not match or are empty. Try again."
    fi
  done

  # ======== 5 manual inputs (Wi-Fi + IPv4) ========
  local SSID_VALUE PSK_VALUE IPV4_ADDR IPV4_GW IPV4_DNS
  SSID_VALUE="$(prompt_nonempty "Wi-Fi SSID: ")"
  PSK_VALUE="$(prompt_nonempty "Wi-Fi PSK: ")"
  IPV4_ADDR="$(prompt_nonempty "IPv4 address with CIDR (e.g. 192.168.0.140/24): ")"
  IPV4_GW="$(prompt_nonempty "Gateway (e.g. 192.168.0.1): ")"
  IPV4_DNS="$(prompt_nonempty "DNS server (e.g. 192.168.0.1): ")"

  # Build NM files
  local NM_CONTENT_A NM_CONTENT_B
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

  sudo mkdir -p "$NM_DIR"
  echo "$NM_CONTENT_A" | sudo tee "$NM_FILE_A" >/dev/null
  echo "$NM_CONTENT_B" | sudo tee "$NM_FILE_B" >/dev/null
  sudo chown root:root "$NM_FILE_A" "$NM_FILE_B"
  sudo chmod 600 "$NM_FILE_A" "$NM_FILE_B"
  sudo systemctl reload NetworkManager 2>/dev/null || true
  sudo nmcli connection reload 2>/dev/null || true
  status_ok "[OK] Network profiles written."

  # RetroPie shutdown script: auto-select "No"
  status_info "Installing RetroPie shutdown script (auto-select 'No')..."
  local TMPDIR2
  TMPDIR2="$(mktemp -d)"
  pushd "$TMPDIR2" >/dev/null
  wget -O "$REPO_ZIP_NAME" "$REPO_ZIP_URL"
  unzip -o "$REPO_ZIP_NAME" >/dev/null
  cd "$REPO_DIR_NAME"
  printf 'n\n' | sudo sh install.sh retropie
  popd >/dev/null
  rm -rf "$TMPDIR2"

  # ======== Final summary ========
  print_hr
  echo "SUMMARY (review before reboot)"
  print_hr
  echo " Root password:    [hidden]"
  echo " Wi-Fi SSID:       $SSID_VALUE"
  echo " Wi-Fi PSK:        $PSK_VALUE"
  echo " IPv4 Address:     $IPV4_ADDR"
  echo " Gateway:          $IPV4_GW"
  echo " DNS:              $IPV4_DNS"
  echo "------------------------------------------"
  echo "Manual edit locations:"
  echo " - SSH config: $SSH_CONFIG_PATH"
  echo " - Network:    $NM_FILE_A"
  echo "               $NM_FILE_B"
  echo "------------------------------------------"
  read -rp "Press ENTER to reboot now (or Ctrl+C to cancel and edit files manually)..." _

  status_ok "Rebooting..."
  sudo reboot || sudo shutdown -r now
}

# ===================== Ops Tools (Reconfigure, Update, Net Checks) =====================
runner_install_via_external_installer() {
  bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)
}

ops_tools_menu() {
  while true; do
    clear || true
    echo "==== Ops Tools ===="
    echo "1) Reconfigure runner (stop & purge state; re-register interactively)"
    echo "2) Update runner binary (via external installer)"
    echo "3) Show runner service status"
    echo "4) Tail runner logs (last 200 lines)"
    echo "5) Network checks (curl + nc) to Gitea"
    echo "b) Back"
    read -rp "> " op
    case "$op" in
      1)
        status_info "Stopping runner & purging config/state ..."
        sudo systemctl stop gitea-runner || true
        rm -rf "$HOME/.config/act_runner" 2>/dev/null || true
        local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS
        INSTANCE_URL="$(ask "INSTANCE_URL" "${PREFILL_INSTANCE_URL:-http://192.168.0.140:3000/}")"
        REG_TOKEN="$(ask "Registration token" "${PREFILL_TOKEN:-}")"
        RUNNER_NAME="$(ask "Runner name" "runner-pi")"
        RUNNER_LABELS="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"
        if [[ -z "$REG_TOKEN" ]]; then
          status_err "REG_TOKEN is required to register."
        else
          act_runner register \
            --instance "${INSTANCE_URL}" \
            --token "${REG_TOKEN}" \
            --name "${RUNNER_NAME}" \
            --labels "${RUNNER_LABELS}"
          sudo systemctl start gitea-runner || true
          status_ok "Runner reconfigured ✅"
        fi
        pause
        ;;
      2)
        status_info "Updating via external installer ..."
        runner_install_via_external_installer
        pause
        ;;
      3)
        _systemctl_status gitea-runner
        pause
        ;;
      4)
        _journal_tail gitea-runner 200
        pause
        ;;
      5)
        local ip port
        ip="$(ask "Gitea IP/host" "192.168.0.140")"
        port="$(ask "Gitea HTTP port" "3000")"
        echo "curl check:"
        curl -I "http://${ip}:${port}/" || echo "cannot reach :${port}"
        echo "nc check:"
        if have_cmd nc; then
          nc -vz "$ip" "$port" || true
        else
          status_warn "nc not installed; run: sudo apt install -y netcat-openbsd"
        fi
        pause
        ;;
      b|B) break ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

# ===================== First Install (Recommended) =====================
first_install_flow() {
  print_hr
  echo "First install: Gitea config (+install if missing) + generate token (CLI) + install runner"
  print_hr
  gitea_server_flow
  runner_flow
}

# ===================== Smoke-test Workflow Printer =====================
print_workflow_snippet() {
  print_hr
  echo ".gitea/workflows/ci.yml (basic smoke test)"
  print_hr
  cat <<'YML'
name: CI
on:
  push:
    branches: [ main ]

jobs:
  hello:
    runs-on: [ self-hosted ]
    steps:
      - name: Print env
        run: |
          echo "Hello from $HOSTNAME"
          uname -a
          lscpu | sed -n '1,10p' || true
YML
  echo
  status_info "Commit & push to main; watch the Actions tab."
  pause
}

# ===================== Main Menu =====================
main_menu() {
  while true; do
    clear || true
    echo "========== Gitea / Runner Setup =========="
    echo "0) First install: Gitea config + generate token (CLI) + install runner"
    echo "1) Gitea (server): install if missing, enable Actions, set ROOT_URL, restart, optional token"
    echo "2) Runner: install if missing OR re-register existing"
    echo "3) Show smoke-test workflow snippet"
    echo "4) Ops tools (reconfigure/update/logs/net)"
    echo "5) Fresh OS setup (root SSH + Wi-Fi SSID/PSK + IPv4/GW/DNS) — auto 'No' RetroPie + summary + reboot"
    echo "q) Quit"
    echo "------------------------------------------"
    read -rp "> " choice
    case "$choice" in
      0) first_install_flow ;;
      1) gitea_server_flow ;;
      2) runner_flow ;;
      3) print_workflow_snippet ;;
      4) ops_tools_menu ;;
      5) fresh_os_flow ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

main_menu
