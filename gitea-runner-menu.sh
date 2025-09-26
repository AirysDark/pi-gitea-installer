#!/usr/bin/env bash
# gitea-runner-menu.sh
# Menu-driven helper for installing/uninstalling Gitea server and runners on Pi/Debian.
set -euo pipefail

# --------- Helpers ----------
ask() { # ask "Prompt" "default"
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
print_hr() { printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '-'; }
status_ok()  { echo -e "\e[32m$*\e[0m"; }
status_info(){ echo -e "\e[36m$*\e[0m"; }
status_warn(){ echo -e "\e[33m$*\e[0m"; }
status_err() { echo -e "\e[31m$*\e[0m"; }

# --------- Install Gitea server ----------
install_gitea_server(){
  print_hr
  echo "Install Gitea server & configs"
  print_hr

  if ! have_cmd gitea; then
    status_info "Gitea not found, installing..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y git build-essential sqlite3 nginx fcgiwrap
    wget -O gitea https://dl.gitea.io/gitea/1.21.11/gitea-1.21.11-linux-arm64
    chmod +x gitea
    sudo mv gitea /usr/local/bin/

    sudo adduser --system --group --disabled-password --home /home/git git || true
    sudo mkdir -p /var/lib/gitea/{custom,data,log}
    sudo chown -R git:git /var/lib/gitea/
    sudo chmod -R 750 /var/lib/gitea/

    sudo tee /etc/systemd/system/gitea.service >/dev/null <<EOF
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
  fi

  local ip port proto
  ip="$(ask "Enter Gitea host/IP" "192.168.0.140")"
  port="$(ask "Enter Gitea port" "3000")"
  proto="$(ask "Protocol" "http")"

  local root_url="${proto}://${ip}:${port}/"
  sudo mkdir -p /etc/gitea
  sudo tee /etc/gitea/app.ini >/dev/null <<EOF
[server]
PROTOCOL  = http
HTTP_ADDR = 0.0.0.0
HTTP_PORT = ${port}
ROOT_URL  = ${root_url}

[actions]
ENABLED = true
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable gitea
  sudo systemctl restart gitea

  if curl -sfL "${root_url}" -o /dev/null; then
    status_ok "Gitea running at ${root_url} ✅"
  else
    status_err "Gitea not reachable ❌"
  fi
  pause
}

# --------- Install runner ----------
install_runner(){
  print_hr
  echo "Install Runner (act_runner)"
  print_hr

  if ! have_cmd act_runner; then
    status_info "Runner not found, installing..."
    sudo apt-get update -y
    sudo apt-get install -y curl unzip
    curl -L "https://gitea.com/gitea/act_runner/releases/download/v0.2.10/act_runner-0.2.10-linux-arm64" -o /tmp/act_runner
    chmod +x /tmp/act_runner
    sudo mv /tmp/act_runner /usr/local/bin/act_runner
  fi

  local instance_url reg_token runner_name runner_labels
  instance_url="$(ask "Gitea INSTANCE_URL" "http://192.168.0.140:3000/")"
  reg_token="$(ask "Registration token" "")"
  runner_name="$(ask "Runner name" "runner-pi")"
  runner_labels="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${runner_name}")"

  mkdir -p "$HOME/.config/act_runner"
  act_runner register \
    --instance "$instance_url" \
    --token "$reg_token" \
    --name "$runner_name" \
    --labels "$runner_labels"

  sudo tee /etc/systemd/system/gitea-runner.service >/dev/null <<EOF
[Unit]
Description=Gitea Actions Runner
After=network-online.target
Wants=network-online.target

[Service]
User=$USER
Group=$USER
Environment=HOME=$HOME
Environment=XDG_CONFIG_HOME=$HOME/.config
WorkingDirectory=$HOME
ExecStart=/usr/local/bin/act_runner daemon
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable gitea-runner
  sudo systemctl restart gitea-runner
  status_ok "Runner installed and started ✅"
  pause
}

# --------- Runner hook ----------
runner_hook(){
  print_hr
  echo "Hook runner to Gitea server"
  print_hr
  status_info "Ensure you have a valid registration token in Gitea (UI or CLI)."
  echo "Then re-run 'Install runner' option if you need to re-register."
  pause
}

# --------- Smoke test workflow ----------
print_workflow_snippet(){
  print_hr
  echo "CI workflow snippet (.gitea/workflows/ci.yml):"
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
  pause
}

# --------- Uninstall Gitea ----------
uninstall_gitea_only(){
  print_hr; status_warn "Uninstall Gitea SERVER only"; local sure; sure="$(ask "Proceed? (yes/no)" "no")"
  [[ "$sure" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; return 0; }

  sudo systemctl stop gitea 2>/dev/null || true
  sudo systemctl disable gitea 2>/dev/null || true

  sudo rm -f /etc/systemd/system/gitea.service
  sudo rm -f /usr/local/bin/gitea
  sudo rm -rf /etc/gitea /var/lib/gitea

  if id "git" &>/dev/null; then
    sudo deluser --remove-home git || true
  fi

  sudo systemctl daemon-reload
  status_ok "Gitea server uninstalled ✅"
  pause
}

# --------- Uninstall Runner ----------
uninstall_runner_only(){
  print_hr; status_warn "Uninstall Runner ONLY"; local sure; sure="$(ask "Proceed? (yes/no)" "no")"
  [[ "$sure" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; return 0; }

  sudo systemctl stop gitea-runner 2>/dev/null || true
  sudo systemctl disable gitea-runner 2>/dev/null || true

  sudo rm -f /etc/systemd/system/gitea-runner.service
  sudo rm -f /usr/local/bin/act_runner
  sudo rm -rf /home/*/.config/act_runner
  [[ -n "${HOME:-}" ]] && rm -rf "$HOME/.config/act_runner" 2>/dev/null || true

  sudo systemctl daemon-reload
  status_ok "Runner uninstalled ✅"
  pause
}

# --------- Main menu ----------
main_menu(){
  while true; do
    clear || true
    echo "========== Gitea / Runner Setup =========="
    echo "0) Install Gitea server & configs"
    echo "1) Install runner"
    echo "2) Runner hook to Gitea"
    echo "3) Show smoke-test workflow snippet"
    echo "6) Uninstall Gitea server"
    echo "7) Uninstall runner"
    echo "q) Quit"
    echo "------------------------------------------"
    choice="$(ask "Choose an option" "")"
    case "$choice" in
      0) install_gitea_server ;;
      1) install_runner ;;
      2) runner_hook ;;
      3) print_workflow_snippet ;;
      6) uninstall_gitea_only ;;
      7) uninstall_runner_only ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

main_menu
