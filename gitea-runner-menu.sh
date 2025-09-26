#!/usr/bin/env bash
# gitea-runner-menu.sh
# All-in-one helper for Gitea server/runner + MySQL/MariaDB on Pi/Debian.
set -euo pipefail

# --- Ensure netcat is available for network checks (requested) ---
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y netcat-openbsd >/dev/null 2>&1 || true

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
_systemctl() { (sudo systemctl "$@" 2>/dev/null) || (systemctl --user "$@" 2>/dev/null || true); }
_systemctl_status() { _systemctl status "$@" --no-pager || true; }
_journal_tail() { (sudo journalctl -u "$1" -n "${2:-200}" --no-pager 2>/dev/null) || true; }

# Resolve runner service user from systemd unit (fallback to $USER)
get_runner_user() {
  local unit="/etc/systemd/system/gitea-runner.service"
  if [[ -f "$unit" ]] && grep -qE '^[[:space:]]*User=' "$unit"; then
    grep -E '^[[:space:]]*User=' "$unit" | tail -n1 | cut -d= -f2 | xargs
  else
    echo "${USER}"
  fi
}

# --------- 0) Install Gitea server & configs ----------
install_gitea_server(){
  print_hr
  echo "Install Gitea server & configs"
  print_hr

  if ! have_cmd gitea; then
    status_info "Gitea not found, installing..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y git build-essential sqlite3 nginx fcgiwrap curl wget
    wget -O gitea https://dl.gitea.io/gitea/1.21.11/gitea-1.21.11-linux-arm64
    chmod +x gitea
    sudo mv gitea /usr/local/bin/

    sudo adduser --system --group --disabled-password --home /home/git git || true
    sudo mkdir -p /var/lib/gitea/{custom,data,log}
    sudo chown -R git:git /var/lib/gitea/
    sudo chmod -R 750 /var/lib/gitea/

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
  fi

  local ip port proto
  ip="$(ask "Enter Gitea host/IP" "192.168.0.140")"
  port="$(ask "Enter Gitea port" "3000")"
  proto="$(ask "Protocol" "http")"
  local root_url="${proto}://${ip}:${port}/"

  sudo mkdir -p /etc/gitea /var/lib/gitea/custom/conf
  sudo tee /etc/gitea/app.ini >/dev/null <<EOF
[server]
PROTOCOL  = http
HTTP_ADDR = 0.0.0.0
HTTP_PORT = ${port}
ROOT_URL  = ${root_url}

[actions]
ENABLED = true
EOF
  sudo cp /etc/gitea/app.ini /var/lib/gitea/custom/conf/app.ini
  sudo chown git:git /var/lib/gitea/custom/conf/app.ini || true
  sudo chmod 640 /var/lib/gitea/custom/conf/app.ini

  sudo systemctl daemon-reload
  sudo systemctl enable gitea
  sudo systemctl restart gitea

  status_info "Health check ${root_url} ..."
  if curl -sfL "${root_url}" -o /dev/null; then
    status_ok "Gitea running at ${root_url} ✅"
  else
    status_err "Gitea not reachable ❌ (check firewall/ports/logs)"
  fi
  pause
}

# --------- 1) Install runner (install/re-register + restart) ----------
install_runner(){
  print_hr
  echo "Install runner (act_runner) — install if missing OR re-register existing"
  print_hr

  local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS RUNNER_VERSION INSTALL_DIR SERVICE_USER
  INSTANCE_URL="$(ask "Gitea INSTANCE_URL" "http://192.168.0.140:3000/")"
  REG_TOKEN="$(ask "Registration token (from Gitea UI/CLI)" "")"
  RUNNER_NAME="$(ask "Runner name" "runner-pi")"
  RUNNER_LABELS="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"
  RUNNER_VERSION="$(ask "act_runner version" "0.2.10")"
  INSTALL_DIR="$(ask "Install dir for act_runner" "/usr/local/bin")"
  SERVICE_USER="$(ask "Systemd service user" "$(get_runner_user)")"
  [[ -n "$REG_TOKEN" ]] || { status_err "REG_TOKEN is required."; pause; return 1; }

  if ! have_cmd act_runner; then
    status_info "Installing act_runner ${RUNNER_VERSION} ..."
    sudo apt-get update -y && sudo apt-get install -y curl unzip
    curl -L "https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-arm64" -o /tmp/act_runner
    chmod +x /tmp/act_runner && sudo mv /tmp/act_runner "${INSTALL_DIR}/act_runner"
  else
    status_info "act_runner already present."
  fi

  status_info "Registering runner..."
  mkdir -p "$HOME/.config/act_runner"
  "${INSTALL_DIR}/act_runner" register \
    --instance "${INSTANCE_URL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}"

  sudo tee /etc/systemd/system/gitea-runner.service >/dev/null <<EOF
[Unit]
Description=Gitea Actions Runner
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=/home/${SERVICE_USER}
Environment=XDG_CONFIG_HOME=/home/${SERVICE_USER}/.config
WorkingDirectory=/home/${SERVICE_USER}
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

# --------- 2) Runner hook to Gitea (re-register only) ----------
runner_hook(){
  print_hr
  echo "Hook runner to Gitea (re-register without reinstalling binary)"
  print_hr

  if ! have_cmd act_runner; then
    status_err "act_runner not found. Run option 1 (Install runner) first."
    pause; return 1
  fi

  local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS INSTALL_DIR
  INSTANCE_URL="$(ask "Gitea INSTANCE_URL" "http://192.168.0.140:3000/")"
  REG_TOKEN="$(ask "Registration token" "")"
  RUNNER_NAME="$(ask "Runner name" "runner-pi")"
  RUNNER_LABELS="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"
  INSTALL_DIR="$(dirname "$(command -v act_runner)")"
  [[ -n "$REG_TOKEN" ]] || { status_err "REG_TOKEN is required."; pause; return 1; }

  status_info "Stopping gitea-runner..."
  sudo systemctl stop gitea-runner 2>/dev/null || true
  status_info "Clearing previous runner state (~/.config/act_runner)..."
  rm -rf "$HOME/.config/act_runner" 2>/dev/null || true

  status_info "Registering to ${INSTANCE_URL} ..."
  "${INSTALL_DIR}/act_runner" register \
    --instance "${INSTANCE_URL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}"

  status_info "Starting gitea-runner..."
  sudo systemctl start gitea-runner 2>/dev/null || true

  status_ok "Runner hooked to Gitea ✅"
  _systemctl_status gitea-runner
  echo; status_info "Recent logs:"; _journal_tail gitea-runner 60
  pause
}

# --------- 3) Smoke test workflow ----------
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

# --------- 4) Ops tools ----------
ops_tools_menu(){
  while true; do
    clear || true
    echo "==== Ops Tools ===="
    echo "1) Reconfigure runner (purge state & re-register interactively)"
    echo "2) Update runner binary (external installer)"
    echo "3) Show runner service status"
    echo "4) Tail runner logs (last 200 lines)"
    echo "5) Network checks to Gitea (curl + nc)"
    echo "6) Runner → MySQL connectivity test (run as service user)"
    echo "b) Back"
    read -rp "> " op
    case "$op" in
      1)
        status_info "Stopping runner & purging state..."
        sudo systemctl stop gitea-runner || true
        rm -rf "$HOME/.config/act_runner" 2>/dev/null || true
        local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS
        INSTANCE_URL="$(ask "INSTANCE_URL" "http://192.168.0.140:3000/")"
        REG_TOKEN="$(ask "Registration token" "")"
        RUNNER_NAME="$(ask "Runner name" "runner-pi")"
        RUNNER_LABELS="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"
        if [[ -z "$REG_TOKEN" ]]; then
          status_err "REG_TOKEN required."
        else
          act_runner register --instance "${INSTANCE_URL}" --token "${REG_TOKEN}" --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}"
          sudo systemctl start gitea-runner || true
          status_ok "Runner reconfigured ✅"
        fi
        pause
        ;;
      2)
        status_info "Updating runner via external installer..."
        bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)
        pause
        ;;
      3) _systemctl_status gitea-runner; pause ;;
      4) _journal_tail gitea-runner 200; pause ;;
      5)
        local ip port
        ip="$(ask "Gitea IP/host" "192.168.0.140")"
        port="$(ask "Gitea HTTP port" "3000")"
        echo "curl check:"; curl -I "http://${ip}:${port}/" || echo "cannot reach :${port}"
        echo "nc check:"; nc -vz "$ip" "$port" || true
        pause
        ;;
      6)
        # Runner -> MySQL connectivity test (as service user)
        local DB_HOST DB_NAME DB_USER DB_PASS SVC_USER
        DB_HOST="$(ask "MySQL host/IP" "192.168.0.130")"
        DB_NAME="$(ask "Database name" "gitea")"
        DB_USER="$(ask "DB username" "gitea")"
        read -rsp "DB password: " DB_PASS; echo
        SVC_USER="$(ask "Runner service user (detected)" "$(get_runner_user)")"

        status_info "Ensuring mariadb-client is installed..."
        sudo apt-get update -y >/dev/null 2>&1 || true
        sudo apt-get install -y mariadb-client >/dev/null 2>&1 || true

        status_info "Testing as user '${SVC_USER}' ..."
        if sudo -u "${SVC_USER}" bash -lc "mysql -h '${DB_HOST}' -u '${DB_USER}' -p'${DB_PASS}' '${DB_NAME}' -e 'SELECT 1;'" >/dev/null 2>&1; then
          status_ok "✅ Runner (${SVC_USER}) can reach MySQL @ ${DB_HOST} and auth to DB '${DB_NAME}'"
        else
          status_err "❌ Runner (${SVC_USER}) could not connect. Check bind-address, firewall, grants, password."
          echo "Hints:"
          echo "  - On DB server: /etc/mysql/mariadb.conf.d/50-server.cnf -> # bind-address = 127.0.0.1 ; then restart mariadb"
          echo "  - Grants: CREATE USER 'user'@'%' IDENTIFIED BY 'pass'; GRANT ALL ON db.* TO 'user'@'%'; FLUSH PRIVILEGES;"
          echo "  - Network: nc -vz ${DB_HOST} 3306"
        fi
        pause
        ;;
      b|B) break ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

# --------- 5) SSHD Activate ----------
sshd_activate_flow(){
  print_hr
  echo "SSHD Activate — write minimal sshd_config to allow password login (incl. root), then restart SSH."
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
  [[ -f "$SSH_CONFIG_PATH" ]] && sudo cp -a "$SSH_CONFIG_PATH" "$SSH_CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  status_info "Writing new sshd_config..."
  echo "$SSHD_CONFIG_CONTENT" | sudo tee "$SSH_CONFIG_PATH" >/dev/null
  status_info "Restarting SSH..."
  sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
  status_ok "SSHD activated ✅  (PasswordAuthentication=yes, PermitRootLogin=yes)"
  echo "Edit if needed: $SSH_CONFIG_PATH"
  pause
}

# --------- 6) Uninstall Gitea ----------
uninstall_gitea_only(){
  print_hr; status_warn "Uninstall Gitea SERVER only"; local sure; sure="$(ask "Proceed? (yes/no)" "no")"
  [[ "$sure" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; return 0; }

  sudo systemctl stop gitea 2>/dev/null || true
  sudo systemctl disable gitea 2>/dev/null || true

  sudo rm -f /etc/systemd/system/gitea.service
  sudo rm -f /usr/local/bin/gitea
  sudo rm -rf /etc/gitea /var/lib/gitea

  if id "git" &>/dev/null; then
    local del; del="$(ask "Delete 'git' user and its home? (yes/no)" "no")"
    [[ "$del" =~ ^y(es)?$ ]] && sudo deluser --remove-home git || true
  fi

  sudo systemctl daemon-reload
  status_ok "Gitea server uninstalled ✅"
  pause
}

# --------- 7) Uninstall Runner ----------
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

# --------- 8) MySQL/MariaDB setup (Server / Client / Uninstall / Test Server / Test Client) ----------
mysql_menu(){
  print_hr
  echo "MySQL/MariaDB Setup Manager"
  print_hr
  PS3="Choose mode: "
  select MODE in "Server" "Client" "Uninstall" "Test Server" "Test Client" "Back"; do
    case "${MODE:-}" in
      Server)
        read -rp "Enter MySQL root password (will be set): " DB_ROOT_PASS
        read -rp "Enter database name for Gitea: " DB_NAME
        read -rp "Enter Gitea DB username: " DB_USER
        read -rsp "Enter Gitea DB user password: " DB_PASS; echo
        read -rp "Enter Gitea domain/IP (default 192.168.0.130): " GITEA_DOMAIN
        GITEA_DOMAIN="${GITEA_DOMAIN:-192.168.0.130}"

        status_info "Installing MariaDB server + client..."
        sudo apt-get update -y
        sudo apt-get install -y mariadb-server mariadb-client

        status_info "Starting/Enabling MariaDB..."
        sudo systemctl enable mariadb
        sudo systemctl start mariadb

        status_info "Securing root account..."
        sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;"

        status_info "Creating database & user..."
        sudo mysql -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
EOF

        status_info "Allowing remote connections (unbinding 127.0.0.1)..."
        MARIADB_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
        if [[ -f "$MARIADB_CONF" ]]; then
          sudo sed -i 's/^[[:space:]]*bind-address[[:space:]]*=.*$/# bind-address = 127.0.0.1/' "$MARIADB_CONF" || true
        fi
        sudo systemctl restart mariadb

        status_info "Writing Gitea app.ini for MySQL..."
        sudo mkdir -p /etc/gitea /var/lib/gitea/custom/conf
        sudo tee /etc/gitea/app.ini >/dev/null <<EOF
[server]
PROTOCOL = http
HTTP_PORT = 3000
DOMAIN = ${GITEA_DOMAIN}
ROOT_URL = http://${GITEA_DOMAIN}:3000/
STATIC_URL_PREFIX = /

[actions]
ENABLED = true

[database]
DB_TYPE  = mysql
HOST     = 127.0.0.1:3306
NAME     = ${DB_NAME}
USER     = ${DB_USER}
PASSWD   = ${DB_PASS}
SCHEMA   =
SSL_MODE = disable

[repository]
ROOT = /var/lib/gitea/data/gitea-repositories

[log]
MODE = console
LEVEL = info
EOF
        sudo cp /etc/gitea/app.ini /var/lib/gitea/custom/conf/app.ini
        sudo chown git:git /var/lib/gitea/custom/conf/app.ini || true
        sudo chmod 640 /var/lib/gitea/custom/conf/app.ini

        status_info "Restarting Gitea..."
        sudo systemctl restart gitea || true

        cat <<INFO

✅ MariaDB SERVER + Gitea config installed!

Root password: ${DB_ROOT_PASS}

Database: ${DB_NAME}
User:     ${DB_USER}
Password: ${DB_PASS}
Gitea URL: http://${GITEA_DOMAIN}:3000/

INFO
        pause
        ;;
      Client)
        read -rp "Enter MySQL server host/IP: " DB_HOST
        read -rp "Enter database name: " DB_NAME
        read -rp "Enter DB username: " DB_USER
        read -rsp "Enter DB password: " DB_PASS; echo

        status_info "Installing MariaDB client..."
        sudo apt-get update -y
        sudo apt-get install -y mariadb-client

        status_info "Writing client template: \$HOME/.config/client-app.ini"
        mkdir -p "$HOME/.config"
        tee "$HOME/.config/client-app.ini" >/dev/null <<EOF
[database]
DB_TYPE  = mysql
HOST     = ${DB_HOST}:3306
NAME     = ${DB_NAME}
USER     = ${DB_USER}
PASSWD   = ${DB_PASS}
SCHEMA   =
SSL_MODE = disable
EOF
        status_ok "✅ MariaDB CLIENT installed! Template: $HOME/.config/client-app.ini"
        pause
        ;;
      Uninstall)
        status_warn "This will remove MariaDB server/client and data."
        read -rp "Proceed? (yes/no) [no]: " ans
        if [[ "${ans:-no}" =~ ^y(es)?$ ]]; then
          status_info "Stopping MariaDB..."
          sudo systemctl stop mariadb || true

          status_info "Removing packages..."
          sudo apt-get purge -y mariadb-server mariadb-client mariadb-common || true
          sudo apt-get autoremove -y || true
          sudo apt-get autoclean -y || true

          status_info "Removing configs/data..."
          sudo rm -rf /etc/mysql /var/lib/mysql "$HOME/.config/client-app.ini"

          status_ok "✅ MariaDB and client configs uninstalled!"
        else
          echo "Aborted."
        fi
        pause
        ;;
      "Test Server")
        read -rp "Enter DB host (default 127.0.0.1): " DB_HOST
        DB_HOST="${DB_HOST:-127.0.0.1}"
        read -rp "Enter DB user: " DB_USER
        read -rsp "Enter DB password: " DB_PASS; echo
        read -rp "Enter DB name: " DB_NAME

        status_info "Testing server DB connection (mysql -h $DB_HOST -u $DB_USER ... $DB_NAME)"
        if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
          status_ok "✅ Server test OK"
        else
          status_err "❌ Server test FAILED"
        fi
        pause
        ;;
      "Test Client")
        read -rp "Enter DB host/IP: " DB_HOST
        read -rp "Enter DB user: " DB_USER
        read -rsp "Enter DB password: " DB_PASS; echo
        read -rp "Enter DB name: " DB_NAME

        status_info "Testing client DB connection (mysql -h $DB_HOST -u $DB_USER ... $DB_NAME)"
        if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
          status_ok "✅ Client test OK"
        else
          status_err "❌ Client test FAILED"
        fi
        pause
        ;;
      Back) break ;;
      *) echo "Invalid choice";;
    esac
  done
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
    echo "4) Ops tools (reconfigure/update/logs/net + runner→MySQL test)"
    echo "5) SSHD Activate (enable password login; restart ssh)"
    echo "6) Uninstall Gitea server"
    echo "7) Uninstall runner"
    echo "8) MySQL/MariaDB setup (Server / Client / Uninstall / Test Server / Test Client)"
    echo "q) Quit"
    echo "------------------------------------------"
    choice="$(ask "Choose an option" "")"
    case "$choice" in
      0) install_gitea_server ;;
      1) install_runner ;;
      2) runner_hook ;;
      3) print_workflow_snippet ;;
      4) ops_tools_menu ;;
      5) sshd_activate_flow ;;
      6) uninstall_gitea_only ;;
      7) uninstall_runner_only ;;
      8) mysql_menu ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

main_menu
