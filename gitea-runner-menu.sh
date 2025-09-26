#!/usr/bin/env bash
# gitea-runner-menu.sh
# Menu wired per request:
# 0) Install Gitea server configs  — install if missing, write configs, enable Actions, set ROOT_URL, restart, health check
# 1) Install runner                — install act_runner if missing OR re-register existing, restart service
# 2) Runner hook to Gitea          — register this runner to a Gitea instance (token/URL/name/labels), restart service
# 3) Smoke-test workflow snippet
# 4) Ops tools (reconfigure/update/logs/net)
# 5) SSHD Activate (enable password login; restart ssh)
# 6) Uninstall Gitea (server only)
# 7) Uninstall Runner (act_runner only)
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

# ===================== 0) Install Gitea server configs =====================
install_gitea_server_configs() {
  print_hr
  echo "Install Gitea server configs: install if missing, write config, enable Actions, set ROOT_URL, restart, health check"
  print_hr

  if ! have_cmd gitea; then
    gitea_bootstrap_install
  fi

  # Detect or default config path
  local default_cfg=""
  if   [[ -f /etc/gitea/app.ini ]]; then default_cfg="/etc/gitea/app.ini"
  elif [[ -f /etc/gitea/conf/app.ini ]]; then default_cfg="/etc/gitea/conf/app.ini"
  elif [[ -f /var/lib/gitea/custom/conf/app.ini ]]; then default_cfg="/var/lib/gitea/custom/conf/app.ini"
  fi

  local cfg_path
  cfg_path="$(ask "Path to app.ini" "${default_cfg:-/var/lib/gitea/custom/conf/app.ini}")"
  sudo mkdir -p "$(dirname "$cfg_path")"
  sudo touch "$cfg_path"

  # IP/URL basics
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
  sudo systemctl restart gitea || status_warn "systemctl restart failed; start service manually if needed."

  status_info "Health check ${root_url} ..."
  if curl -sfL "${root_url}" -o /dev/null; then
    status_ok "Gitea OK ✅"
  else
    status_err "Gitea not reachable ❌ (firewall/ports/service logs?)"
  fi

  pause
}

# ===================== Runner presence check =====================
runner_installed() {
  if have_cmd act_runner; then return 0; fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^gitea-runner\.service'; then return 0; fi
  if systemctl is-active gitea-runner >/dev/null 2>&1; then return 0; fi
  return 1
}

# ===================== 1) Install runner =====================
install_runner() {
  print_hr
  echo "Install runner: install act_runner if missing OR re-register existing, then restart service"
  print_hr

  local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS RUNNER_VERSION INSTALL_DIR SERVICE_USER
  INSTANCE_URL="$(ask "INSTANCE_URL" "${PREFILL_INSTANCE_URL:-http://192.168.0.140:3000/}")"
  REG_TOKEN="$(ask "Registration token (paste from Gitea UI or CLI)" "${PREFILL_TOKEN:-}")"
  RUNNER_NAME="$(ask "Runner name" "runner")"
  RUNNER_LABELS="$(ask "Runner labels (comma-separated)" "self-hosted,linux,arm64,pi")"
  RUNNER_VERSION="$(ask "act_runner version" "0.2.10")"
  INSTALL_DIR="$(ask "Install dir for act_runner" "/usr/local/bin")"
  SERVICE_USER="$(ask "Systemd service user" "$USER")"

  if [[ -z "$REG_TOKEN" ]]; then
    status_err "REG_TOKEN is required."
    pause; return 1
  fi

  # Install deps
  sudo apt-get update -y
  sudo apt-get install -y curl unzip

  # Install act_runner if not present
  if ! have_cmd act_runner; then
    status_info "Installing act_runner ${RUNNER_VERSION} ..."
    curl -L "https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-arm64" -o /tmp/act_runner
    chmod +x /tmp/act_runner
    sudo mv /tmp/act_runner "${INSTALL_DIR}/act_runner"
  else
    status_info "act_runner already present."
  fi

  # (Re)register
  status_info "Registering runner to ${INSTANCE_URL} ..."
  mkdir -p "$HOME/.config/act_runner"
  "${INSTALL_DIR}/act_runner" register \
    --instance "${INSTANCE_URL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}"

  # Create/refresh service
  status_info "Creating/updating systemd service gitea-runner.service ..."
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

  sudo systemctl daemon-reload
  sudo systemctl enable gitea-runner
  sudo systemctl restart gitea-runner

  status_ok "Runner installed/registered and service restarted ✅"
  _systemctl_status gitea-runner
  echo; status_info "Recent logs:"; _journal_tail gitea-runner 60
  pause
}

# ===================== 2) Runner hook to Gitea (register only) =====================
runner_hook_to_gitea() {
  print_hr
  echo "Runner hook to Gitea: register this runner to a Gitea instance and restart service"
  print_hr

  if ! have_cmd act_runner; then
    status_err "act_runner binary not found. Run option 1 (Install runner) first."
    pause; return 1
  fi

  local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS INSTALL_DIR
  INSTANCE_URL="$(ask "INSTANCE_URL" "${PREFILL_INSTANCE_URL:-http://192.168.0.140:3000/}")"
  REG_TOKEN="$(ask "Registration token" "${PREFILL_TOKEN:-}")"
  RUNNER_NAME="$(ask "Runner name" "runner")"
  RUNNER_LABELS="$(ask "Runner labels (comma-separated)" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"
  INSTALL_DIR="$(dirname "$(command -v act_runner)")"

  if [[ -z "$REG_TOKEN" ]]; then
    status_err "REG_TOKEN is required."
    pause; return 1
  fi

  status_info "Stopping runner service (if running) ..."
  sudo systemctl stop gitea-runner || true
  rm -rf "$HOME/.config/act_runner" 2>/dev/null || true

  status_info "Registering to ${INSTANCE_URL} ..."
  "${INSTALL_DIR}/act_runner" register \
    --instance "${INSTANCE_URL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}"

  status_info "Starting runner service ..."
  sudo systemctl start gitea-runner || true
  status_ok "Runner hooked to Gitea ✅"
  _systemctl_status gitea-runner
  echo; status_info "Recent logs:"; _journal_tail gitea-runner 60
  pause
}

# ===================== SSHD Activate (enable password login) =====================
sshd_activate_flow() {
  print_hr
  echo "SSHD Activate: write minimal sshd_config to allow password login (incl. root), then restart SSH."
  print_hr

  local SSH_CONFIG_PATH="/etc/ssh/sshd_config"
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

  status_info "Backing up current sshd_config (if exists)..."
  if [[ -f "$SSH_CONFIG_PATH" ]]; then
    sudo cp -a "$SSH_CONFIG_PATH" "$SSH_CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  fi

  status_info "Writing new sshd_config..."
  echo "$SSHD_CONFIG_CONTENT" | sudo tee "$SSH_CONFIG_PATH" >/dev/null

  status_info "Restarting SSH service..."
  sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

  status_ok "SSHD activated ✅  (PasswordAuthentication=yes, PermitRootLogin=yes)"
  echo "Edit if needed: $SSH_CONFIG_PATH"
  pause
}

# ===================== Uninstallers =====================
uninstall_gitea_only() {
  print_hr
  status_warn "You are about to uninstall Gitea SERVER only (runner unaffected)."
  local sure; sure="$(ask "Proceed? (yes/no)" "no")"
  [[ "$sure" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; return 0; }

  echo "==> Stopping/disabling gitea..."
  sudo systemctl stop gitea || true
  sudo systemctl disable gitea || true

  echo "==> Removing gitea service file..."
  sudo rm -f /etc/systemd/system/gitea.service

  echo "==> Removing gitea binary..."
  sudo rm -f /usr/local/bin/gitea

  echo "==> Removing gitea configs/data..."
  sudo rm -rf /etc/gitea
  sudo rm -rf /var/lib/gitea

  echo "==> (Optional) Removing Gitea user 'git'..."
  if id "git" &>/dev/null; then
    local del; del="$(ask "Delete 'git' user and its home? (yes/no)" "no")"
    if [[ "$del" =~ ^y(es)?$ ]]; then
      sudo deluser --remove-home git || true
    fi
  fi

  echo "==> Reloading systemd..."
  sudo systemctl daemon-reload

  status_ok "✅ Gitea server uninstalled."
  pause
}

uninstall_runner_only() {
  print_hr
  status_warn "You are about to uninstall the Gitea Runner ONLY (server unaffected)."
  local sure; sure="$(ask "Proceed? (yes/no)" "no")"
  [[ "$sure" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; return 0; }

  echo "==> Stopping/disabling gitea-runner..."
  sudo systemctl stop gitea-runner || true
  sudo systemctl disable gitea-runner || true

  echo "==> Removing runner service file..."
  sudo rm -f /etc/systemd/system/gitea-runner.service

  echo "==> Removing runner binary..."
  sudo rm -f /usr/local/bin/act_runner

  echo "==> Removing runner config..."
  sudo rm -rf /home/*/.config/act_runner
  [[ -n "${HOME:-}" ]] && rm -rf "$HOME/.config/act_runner" 2>/dev/null || true

  echo "==> Reloading systemd..."
  sudo systemctl daemon-reload

  status_ok "✅ Gitea runner uninstalled."
  pause
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
    echo "0) Install Gitea server configs"
    echo "1) Install runner"
    echo "2) Runner hook to Gitea"
    echo "3) Show smoke-test workflow snippet"
    echo "4) Ops tools (reconfigure/update/logs/net)"
    echo "5) SSHD Activate (enable password login; restart ssh)"
    echo "6) Uninstall Gitea (server only)"
    echo "7) Uninstall Runner (act_runner only)"
    echo "q) Quit"
    echo "------------------------------------------"
    read -rp "> " choice
    case "$choice" in
      0) install_gitea_server_configs ;;
      1) install_runner ;;
      2) runner_hook_to_gitea ;;
      3) print_workflow_snippet ;;
      4) ops_tools_menu ;;
      5) sshd_activate_flow ;;
      6) uninstall_gitea_only ;;
      7) uninstall_runner_only ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

main_menu
