#!/usr/bin/env bash
# gitea-runner-menu.sh
# All-in-one menu to:
#  - Install & configure Gitea (if missing), enable Actions, set ROOT_URL
#  - Generate a runner registration token (via Gitea CLI if available)
#  - Install & register Gitea Actions runner on this host (Pi/ARM64 friendly)
#  - Show useful ops tools (status, logs, reconfigure, update, net checks)
# Works on Raspberry Pi OS / Debian. Assumes ARM64 runner binary via your installer.
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

# Prefer system units, fall back to user units if needed
_systemctl_status() {
  (sudo systemctl "$@" 2>/dev/null) || (systemctl --user "$@" 2>/dev/null || true)
}

_journal_tail() {
  (sudo journalctl -u "$1" -n "${2:-200}" --no-pager 2>/dev/null) || true
}

# ===================== One-line self installer hint =====================
# Once you host this file somewhere (e.g., your GitHub raw URL), you can run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/gitea-runner-menu.sh)

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

  # Create service if missing
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

  # Normalize any present keys
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

  # Ensure required keys exist even if they were missing
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

  # Optional token generation (instance-level) via CLI
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

# ===================== Runner Install & Register =====================
runner_install_via_installer() {
  # Uses your maintained installer
  bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)
}

runner_flow() {
  print_hr
  echo "Runner install & register (this host)"
  print_hr
  local instance_url reg_token runner_name runner_labels

  instance_url="$(ask "Gitea INSTANCE_URL (e.g., http://192.168.0.140:3000/)" "${PREFILL_INSTANCE_URL:-http://192.168.0.140:3000/}")"
  if [[ -n "${PREFILL_TOKEN}" ]]; then
    status_info "Using prefilled registration token from this session."
    reg_token="$PREFILL_TOKEN"
  else
    reg_token="$(ask "Registration token (paste from Gitea or CLI)" "")"
  fi
  if [[ -z "$reg_token" ]]; then
    status_warn "No token provided; cannot register. Generate one on the server first."
    pause; return 0
  fi

  runner_name="$(ask "Runner name" "runner-pi")"
  runner_labels="$(ask "Runner labels (comma-separated)" "self-hosted,linux,arm64,pi,${runner_name}")"

  export INSTANCE_URL="${instance_url}"
  export REG_TOKEN="${reg_token}"
  export RUNNER_NAME="${runner_name}"
  export RUNNER_LABELS="${runner_labels}"

  status_info "Installing & registering runner via installer ..."
  runner_install_via_installer

  print_hr
  status_info "Service status:"
  _systemctl_status status gitea-runner --no-pager || true
  echo
  status_info "Recent logs:"
  _journal_tail gitea-runner 200
  echo
  status_ok "If registration succeeded, \"${runner_name}\" should show online in Gitea → Runners."
  pause
}

# ===================== Ops Tools (Reconfigure, Update, Net Checks) =====================
ops_tools_menu() {
  while true; do
    clear || true
    echo "==== Ops Tools ===="
    echo "1) Reconfigure runner (stop & purge state; run installer again)"
    echo "2) Update runner binary (re-run installer)"
    echo "3) Show runner service status"
    echo "4) Tail runner logs (last 200 lines)"
    echo "5) Network checks (curl + nc) to Gitea"
    echo "b) Back"
    read -rp "> " op
    case "$op" in
      1)
        status_info "Stopping runner & purging config/state ..."
        sudo systemctl stop gitea-runner || true
        sudo rm -rf /var/lib/gitea-runner/* ~/.config/gitea-runner/* 2>/dev/null || true
        status_info "Re-running installer ..."
        runner_install_via_installer
        pause
        ;;
      2)
        status_info "Stopping runner ..."
        sudo systemctl stop gitea-runner || true
        status_info "Re-running installer to refresh binary/version ..."
        runner_install_via_installer
        sudo systemctl start gitea-runner || true
        pause
        ;;
      3)
        _systemctl_status status gitea-runner --no-pager || true
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
  gitea_server_flow     # sets PREFILL_INSTANCE_URL and maybe PREFILL_TOKEN
  runner_flow           # uses prefilled values; prompts if anything missing
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
    echo "2) Runner: install & register this host as a runner"
    echo "3) Show smoke-test workflow snippet"
    echo "4) Ops tools (reconfigure/update/logs/net)"
    echo "q) Quit"
    echo "------------------------------------------"
    read -rp "> " choice
    case "$choice" in
      0) first_install_flow ;;
      1) gitea_server_flow ;;
      2) runner_flow ;;
      3) print_workflow_snippet ;;
      4) ops_tools_menu ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

main_menu
