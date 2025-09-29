#!/usr/bin/env bash
# gitea-runner-menu.sh
# All-in-one helper for Gitea server/runner + MySQL/MariaDB + No-IP (DDNS) + HTTPS (Nginx+Let's Encrypt) on Pi/Debian.
set -euo pipefail

# --- Ensure netcat is available for network checks ---
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y netcat-openbsd >/dev/null 2>&1 || true

# ==================== THEME ====================
supports_256() { tput colors 2>/dev/null | awk '{exit !($1>=256)}'; }
if supports_256; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_PRIM_BG=$'\e[48;5;17m'; C_PRIM_TX=$'\e[38;5;153m'; C_HEAD_TX=$'\e[38;5;195m'
  C_ACC=$'\e[38;5;81m'; C_MUTED=$'\e[38;5;244m'; C_OK=$'\e[38;5;120m'
  C_WARN=$'\e[38;5;214m'; C_ERR=$'\e[38;5;203m'; C_LINK=$'\e[38;5;110m'; C_BOX=$'\e[38;5;24m'
else
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_PRIM_BG=$'\e[44m'; C_PRIM_TX=$'\e[97m'; C_HEAD_TX=$'\e[97m'
  C_ACC=$'\e[36m'; C_MUTED=$'\e[90m'; C_OK=$'\e[32m'
  C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_LINK=$'\e[36m'; C_BOX=$'\e[34m'
fi
term_width(){ tput cols 2>/dev/null || echo 80; }
hr(){ local w; w=$(term_width); printf '%s\n' "$(printf '%*s' "$w" '' | tr ' ' '─')"; }
pad_center(){ local t="$1" w; w=$(term_width); local l=${#t}; local p=$(( (w-l)/2 )); ((p<0))&&p=0; printf '%*s%s%*s\n' "$p" '' "$t" "$p" ''; }
banner(){ local t="$1" s="${2-}"; local w; w=$(term_width)
  printf "${C_PRIM_BG}${C_HEAD_TX}${C_BOLD}%s\n" "$(printf '%*s' "$w" ' ' )"
  pad_center "⚙  Gitea • Runner • MySQL • No-IP • HTTPS"
  pad_center "$t"
  [[ -n "$s" ]] && pad_center "${C_PRIM_TX}${s}${C_HEAD_TX}"
  printf "%s${C_RESET}\n" "$(printf '%*s' "$w" ' ' )"
}
section(){ local t="$1"
  printf "${C_BOX}┌──────────────────────────────────────────────────────────────────────────┐${C_RESET}\n"
  printf "${C_BOX}│${C_RESET} ${C_BOLD}${C_ACC}%s${C_RESET}\n" "$t"
  printf "${C_BOX}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}\n"
}
msg_ok(){ printf "${C_OK}✔ %s${C_RESET}\n" "$*"; }
msg_info(){ printf "${C_ACC}ℹ %s${C_RESET}\n" "$*"; }
msg_warn(){ printf "${C_WARN}⚠ %s${C_RESET}\n" "$*"; }
msg_err(){ printf "${C_ERR}✖ %s${C_RESET}\n" "$*"; }
print_hr(){ printf "${C_BOX}"; hr; printf "${C_RESET}"; }

# ==================== HELPERS ====================
ask(){ local p="${1:-}" d="${2-}" r
  if [[ -n "$d" ]]; then read -rp "$(printf "${C_ACC}?${C_RESET} %s ${C_MUTED}[%s]${C_RESET}: " "$p" "$d")" r || true; echo "${r:-$d}"
  else read -rp "$(printf "${C_ACC}?${C_RESET} %s: " "$p")" r || true; echo "$r"; fi
}
pause(){ read -rp "$(printf "${C_MUTED}Press Enter to continue...${C_RESET} ")" || true; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
_systemctl(){ (sudo systemctl "$@" 2>/dev/null) || (systemctl --user "$@" 2>/dev/null || true); }
_systemctl_status(){ _systemctl status "$@" --no-pager || true; }
_journal_tail(){ (sudo journalctl -u "$1" -n "${2:-200}" --no-pager 2>/dev/null) || true; }

# Resolve runner service user from systemd unit (fallback to $USER)
get_runner_user(){
  local u="/etc/systemd/system/gitea-runner.service"
  if [[ -f "$u" ]] && grep -qE '^[[:space:]]*User=' "$u"; then grep -E '^[[:space:]]*User=' "$u" | tail -n1 | cut -d= -f2 | xargs
  else echo "${USER}"; fi
}

# ==================== 0) GITEA INSTALL ====================
install_gitea_server(){
  clear; banner "Install Gitea server & configs" "enable Actions • set ROOT_URL • restart"
  section "Preparing Gitea"
  if ! have_cmd gitea; then
    msg_info "Gitea not found, installing..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y git build-essential sqlite3 nginx fcgiwrap curl wget
    # Pin arm64 build for Pi; change if x86_64
    ARCH="$(uname -m)"; BIN_URL=""
    case "$ARCH" in
      aarch64|arm64) BIN_URL="https://dl.gitea.io/gitea/1.21.11/gitea-1.21.11-linux-arm64" ;;
      x86_64|amd64)  BIN_URL="https://dl.gitea.io/gitea/1.21.11/gitea-1.21.11-linux-amd64" ;;
      *) BIN_URL="https://dl.gitea.io/gitea/1.21.11/gitea-1.21.11-linux-arm64" ;;
    esac
    wget -O gitea "$BIN_URL"
    chmod +x gitea && sudo mv gitea /usr/local/bin/
    sudo adduser --system --group --disabled-password --home /home/git git || true
    sudo mkdir -p /var/lib/gitea/{custom,data,log}
    sudo chown -R git:git /var/lib/gitea/ && sudo chmod -R 750 /var/lib/gitea/
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
    msg_ok "Gitea binary and service installed."
  else
    msg_info "Gitea already installed."
  fi

  section "Configure ROOT_URL & enable Actions"
  local ip port proto root_url
  ip="$(ask "Enter Gitea host/IP (for ROOT_URL)" "192.168.0.140")"
  port="$(ask "Enter Gitea port" "3000")"
  proto="$(ask "Protocol (http/https)" "http")"
  root_url="${proto}://${ip}:${port}/"

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

  msg_info "Restarting gitea service..."
  sudo systemctl daemon-reload
  sudo systemctl enable gitea
  sudo systemctl restart gitea

  print_hr
  msg_info "Health check ${root_url} ..."
  if curl -sfL "${root_url}" -o /dev/null; then
    msg_ok "Gitea running at ${C_LINK}${root_url}${C_RESET}"
  else
    msg_err "Gitea not reachable (check firewall/ports/logs)"
  fi
  pause
}

# ==================== 1) RUNNER INSTALL ====================
install_runner(){
  clear; banner "Install runner (act_runner)" "install if missing • register • systemd service"
  section "Runner inputs"
  local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS RUNNER_VERSION INSTALL_DIR SERVICE_USER ARCH
  INSTANCE_URL="$(ask "Gitea INSTANCE_URL" "http://192.168.0.140:3000/")"
  REG_TOKEN="$(ask "Registration token (from Gitea UI/CLI)" "")"
  RUNNER_NAME="$(ask "Runner name" "runner-pi")"
  RUNNER_LABELS="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"
  RUNNER_VERSION="$(ask "act_runner version" "0.2.10")"
  INSTALL_DIR="$(ask "Install dir for act_runner" "/usr/local/bin")"
  SERVICE_USER="$(ask "Systemd service user" "$(get_runner_user)")"
  [[ -n "$REG_TOKEN" ]] || { msg_err "REG_TOKEN is required."; pause; return 1; }

  section "Install/Update act_runner"
  if ! have_cmd act_runner; then
    sudo apt-get update -y && sudo apt-get install -y curl unzip
    ARCH="$(uname -m)"; RUN_URL=""
    case "$ARCH" in
      aarch64|arm64) RUN_URL="https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-arm64" ;;
      x86_64|amd64)  RUN_URL="https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-amd64" ;;
      *) RUN_URL="https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-arm64" ;;
    esac
    curl -L "$RUN_URL" -o /tmp/act_runner
    chmod +x /tmp/act_runner && sudo mv /tmp/act_runner "${INSTALL_DIR}/act_runner"
    msg_ok "act_runner installed."
  else
    msg_info "act_runner already present."
  fi

  section "Register runner"
  mkdir -p "$HOME/.config/act_runner"
  "${INSTALL_DIR}/act_runner" register \
    --instance "${INSTANCE_URL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}"

  section "Create systemd service"
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

  msg_ok "Runner installed/registered and service restarted."
  _systemctl_status gitea-runner
  echo; msg_info "Recent logs:"; _journal_tail gitea-runner 60
  pause
}

# ==================== 2) RUNNER HOOK ====================
runner_hook(){
  clear; banner "Hook runner to Gitea" "re-register without reinstalling binary"
  if ! have_cmd act_runner; then
    msg_err "act_runner not found. Run option 1 (Install runner) first."
    pause; return 1
  fi
  section "Re-registration inputs"
  local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS INSTALL_DIR
  INSTANCE_URL="$(ask "Gitea INSTANCE_URL" "http://192.168.0.140:3000/")"
  REG_TOKEN="$(ask "Registration token" "")"
  RUNNER_NAME="$(ask "Runner name" "runner-pi")"
  RUNNER_LABELS="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"
  INSTALL_DIR="$(dirname "$(command -v act_runner)")"
  [[ -n "$REG_TOKEN" ]] || { msg_err "REG_TOKEN is required."; pause; return 1; }

  section "Stop service & purge prior state"
  sudo systemctl stop gitea-runner 2>/dev/null || true
  rm -rf "$HOME/.config/act_runner" 2>/dev/null || true

  section "Register"
  "${INSTALL_DIR}/act_runner" register \
    --instance "${INSTANCE_URL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}"

  section "Start service"
  sudo systemctl start gitea-runner 2>/dev/null || true

  msg_ok "Runner hooked to Gitea."
  _systemctl_status gitea-runner
  echo; msg_info "Recent logs:"; _journal_tail gitea-runner 60
  pause
}

# ==================== 3) SMOKE TEST ====================
print_workflow_snippet(){
  clear; banner "CI workflow snippet" ".gitea/workflows/ci.yml"
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
  print_hr
  msg_info "Copy the above into .gitea/workflows/ci.yml and push to main."
  pause
}

# ==================== 4) OPS TOOLS ====================
ops_tools_menu(){
  while true; do
    clear; banner "Ops Tools" "status • logs • network • reconfigure"
    echo "${C_BOX}┌──────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo "${C_BOX}│${CRESET} ${C_BOLD}1)${C_RESET} Reconfigure runner (purge & re-register)                                    "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}2)${C_RESET} Update runner binary (external installer)                                    "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}3)${C_RESET} Show runner service status                                                  "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}4)${C_RESET} Tail runner logs (last 200)                                                    "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}5)${C_RESET} Network checks to Gitea (curl + nc)                                           "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}6)${CRESET} Runner → MySQL connectivity test (run as service user)                      "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}b)${C_RESET} Back                                                                  "
    echo "${C_BOX}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    read -rp "$(printf "${C_ACC}> ${C_RESET}")" op
    case "$op" in
      1)
        section "Reconfigure runner"
        sudo systemctl stop gitea-runner || true
        rm -rf "$HOME/.config/act_runner" 2>/dev/null || true
        local INSTANCE_URL REG_TOKEN RUNNER_NAME RUNNER_LABELS
        INSTANCE_URL="$(ask "INSTANCE_URL" "http://192.168.0.140:3000/")"
        REG_TOKEN="$(ask "Registration token" "")"
        RUNNER_NAME="$(ask "Runner name" "runner-pi")"
        RUNNER_LABELS="$(ask "Runner labels" "self-hosted,linux,arm64,pi,${RUNNER_NAME}")"
        if [[ -z "$REG_TOKEN" ]]; then
          msg_err "REG_TOKEN required."
        else
          act_runner register --instance "${INSTANCE_URL}" --token "${REG_TOKEN}" --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}"
          sudo systemctl start gitea-runner || true
          msg_ok "Runner reconfigured."
        fi
        pause
        ;;
      2)
        section "Update runner via external installer"
        bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)
        pause
        ;;
      3) section "Service status"; _systemctl_status gitea-runner; pause ;;
      4) section "Runner logs (last 200)"; _journal_tail gitea-runner 200; pause ;;
      5)
        section "Network checks"
        local ip port
        ip="$(ask "Gitea IP/host" "192.168.0.140")"
        port="$(ask "Gitea HTTP port" "3000")"
        echo "${C_MUTED}curl -I http://${ip}:${port}/${C_RESET}"
        curl -I "http://${ip}:${port}/" || echo "cannot reach :${port}"
        echo "${C_MUTED}nc -vz ${ip} ${port}${C_RESET}"
        nc -vz "$ip" "$port" || true
        pause
        ;;
      6)
        section "Runner → MySQL connectivity test"
        local DB_HOST DB_NAME DB_USER DB_PASS SVC_USER
        DB_HOST="$(ask "MySQL host/IP" "192.168.0.130")"
        DB_NAME="$(ask "Database name" "gitea")"
        DB_USER="$(ask "DB username" "gitea")"
        read -rsp "$(printf "${C_ACC}?${C_RESET} DB password: ")" DB_PASS; echo
        SVC_USER="$(ask "Runner service user (detected)" "$(get_runner_user)")"
        msg_info "Ensuring mariadb-client is installed..."
        sudo apt-get update -y >/dev/null 2>&1 || true
        sudo apt-get install -y mariadb-client >/dev/null 2>&1 || true
        msg_info "Testing as user '${SVC_USER}' ..."
        if sudo -u "${SVC_USER}" bash -lc "mysql -h '${DB_HOST}' -u '${DB_USER}' -p'${DB_PASS}' '${DB_NAME}' -e 'SELECT 1;'" >/dev/null 2>&1; then
          msg_ok "Runner (${SVC_USER}) can reach MySQL @ ${DB_HOST} and auth to DB '${DB_NAME}'"
        else
          msg_err "Runner (${SVC_USER}) could not connect. Check bind-address, firewall, grants, password."
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

# ==================== 5) DNS (NO-IP via ddclient) ====================
dns_noip_menu(){
  while true; do
    clear; banner "DNS (No-IP)" "ddclient-based updater"
    echo "${C_BOX}┌──────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo "${C_BOX}│${C_RESET} ${C_BOLD}1)${C_RESET} Install/Configure No-IP (ddclient)                                       "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}2)${C_RESET} Force update now                                                          "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}3)${C_RESET} Show ddclient service status                                              "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}4)${CRESET} Uninstall No-IP (ddclient)                                                "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}b)${C_RESET} Back                                                                  "
    echo "${C_BOX}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    read -rp "$(printf "${C_ACC}> ${C_RESET}")" dch
    case "$dch" in
      1)
        local NOIP_USER NOIP_PASS NOIP_HOSTS INTERVAL
        NOIP_USER="$(ask "No-IP username (email)" "")"
        read -rsp "$(printf "${C_ACC}?${C_RESET} No-IP password: ")" NOIP_PASS; echo
        NOIP_HOSTS="$(ask "Hostname(s) (comma-separated, e.g. myhost.ddns.net)" "")"
        INTERVAL="$(ask "Update interval seconds" "300")"
        [[ -n "$NOIP_USER" && -n "$NOIP_PASS" && -n "$NOIP_HOSTS" ]] || { msg_err "All fields are required."; pause; continue; }

        msg_info "Installing ddclient..."
        sudo apt-get update -y
        sudo apt-get install -y ddclient

        msg_info "Writing /etc/ddclient.conf ..."
        sudo tee /etc/ddclient.conf >/dev/null <<EOF
# ddclient for No-IP
protocol=dyndns2
use=web, web=checkip.dyndns.com/, web-skip='IP Address'
server=dynupdate.no-ip.com
ssl=yes
login=${NOIP_USER}
password='${NOIP_PASS}'
${NOIP_HOSTS}
EOF
        if [[ -f /etc/default/ddclient ]]; then
          sudo sed -i 's/^run_daemon=.*/run_daemon="true"/' /etc/default/ddclient || true
          sudo sed -i "s/^daemon=.*/daemon=${INTERVAL}/" /etc/default/ddclient || echo "daemon=${INTERVAL}" | sudo tee -a /etc/default/ddclient >/dev/null
        else
          sudo tee /etc/default/ddclient >/dev/null <<EOF
run_daemon="true"
daemon=${INTERVAL}
syslog=yes
EOF
        fi
        sudo systemctl enable ddclient
        sudo systemctl restart ddclient
        sudo ddclient -force -verbose || true
        msg_ok "No-IP (ddclient) installed & configured"
        echo "Config: /etc/ddclient.conf"
        pause
        ;;
      2) msg_info "Forcing ddclient update..."; sudo ddclient -force -verbose && msg_ok "Update sent" || msg_err "Update failed"; pause;;
      3) _systemctl_status ddclient; echo; msg_info "Recent logs (syslog):"; (sudo tail -n 100 /var/log/syslog 2>/dev/null | grep -i ddclient || true); pause;;
      4)
        msg_warn "This will remove ddclient and its config."
        local sure; sure="$(ask "Proceed? (yes/no)" "no")"
        if [[ "$sure" =~ ^y(es)?$ ]]; then
          sudo systemctl stop ddclient || true
          sudo systemctl disable ddclient || true
          sudo apt-get purge -y ddclient || true
          sudo apt-get autoremove -y || true
          sudo rm -f /etc/ddclient.conf /etc/default/ddclient
          msg_ok "No-IP (ddclient) uninstalled"
        else echo "Aborted."; fi
        pause
        ;;
      b|B) break ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

# ==================== 6) UNINSTALL GITEA ====================
uninstall_gitea_only(){
  clear; banner "Uninstall Gitea" "server only"
  local sure; sure="$(ask "Proceed? (yes/no)" "no")"
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
  msg_ok "Gitea server uninstalled."
  pause
}

# ==================== 7) UNINSTALL RUNNER ====================
uninstall_runner_only(){
  clear; banner "Uninstall Runner" "runner only"
  local sure; sure="$(ask "Proceed? (yes/no)" "no")"
  [[ "$sure" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; return 0; }
  sudo systemctl stop gitea-runner 2>/dev/null || true
  sudo systemctl disable gitea-runner 2>/dev/null || true
  sudo rm -f /etc/systemd/system/gitea-runner.service
  sudo rm -f /usr/local/bin/act_runner
  sudo rm -rf /home/*/.config/act_runner
  [[ -n "${HOME:-}" ]] && rm -rf "$HOME/.config/act_runner" 2>/dev/null || true
  sudo systemctl daemon-reload
  msg_ok "Runner uninstalled."
  pause
}

# ==================== 8) MYSQL/MARIADB ====================
mysql_menu(){
  while true; do
    clear; banner "MySQL / MariaDB Setup" "server • client • uninstall • test"
    echo "${C_BOX}┌──────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo "${C_BOX}│${C_RESET} ${C_BOLD}1)${C_RESET} Server (install, create DB/user, integrate with Gitea)                      "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}2)${C_RESET} Client (install and write client-app.ini)                                   "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}3)${C_RESET} Uninstall (server/client and data)                                             "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}4)${C_RESET} Test Server connection                                                         "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}5)${C_RESET} Test Client connection                                                         "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}b)${CRESET} Back                                                                  "
    echo "${C_BOX}└──────────────────────────────────────────────────────────────────────────┘${CRESET}"
    read -rp "$(printf "${C_ACC}> ${C_RESET}")" MODE
    case "${MODE:-}" in
      1)
        clear; banner "MariaDB Server" "install • secure • create DB/user • wire to Gitea"
        local DB_ROOT_PASS DB_NAME DB_USER DB_PASS GITEA_DOMAIN
        DB_ROOT_PASS="$(ask "MySQL root password (set)" "changeme")"
        DB_NAME="$(ask "Database name for Gitea" "gitea")"
        DB_USER="$(ask "Gitea DB username" "gitea")"
        read -rsp "$(printf "${C_ACC}?${C_RESET} Gitea DB user password: ")" DB_PASS; echo
        GITEA_DOMAIN="$(ask "Gitea domain/IP (for ROOT_URL)" "192.168.0.130")"
        msg_info "Installing MariaDB server + client..."
        sudo apt-get update -y
        sudo apt-get install -y mariadb-server mariadb-client
        sudo systemctl enable mariadb && sudo systemctl start mariadb
        msg_info "Securing root user..."
        sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;"
        msg_info "Creating DB & user..."
        sudo mysql -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
EOF
        msg_info "Allowing remote connections..."
        local MARIADB_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
        if [[ -f "$MARIADB_CONF" ]]; then
          sudo sed -i 's/^[[:space:]]*bind-address[[:space:]]*=.*$/# bind-address = 127.0.0.1/' "$MARIADB_CONF" || true
        fi
        sudo systemctl restart mariadb

        msg_info "Writing Gitea app.ini for MySQL..."
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
        sudo systemctl restart gitea || true

        print_hr
        echo "  ${C_BOLD}Root password:${C_RESET} ${DB_ROOT_PASS}"
        echo "  ${C_BOLD}Database:${C_RESET} ${DB_NAME}"
        echo "  ${C_BOLD}User:${CRESET}     ${DB_USER}"
        echo "  ${C_BOLD}Password:${C_RESET} ${DB_PASS}"
        echo "  ${C_BOLD}Gitea URL:${C_RESET} ${C_LINK}http://${GITEA_DOMAIN}:3000/${C_RESET}"
        print_hr
        msg_ok "MariaDB SERVER + Gitea config installed."
        pause
        ;;
      2)
        clear; banner "MariaDB Client" "install and write client-app.ini"
        local DB_HOST DB_NAME DB_USER DB_PASS
        DB_HOST="$(ask "MySQL server host/IP" "192.168.0.130")"
        DB_NAME="$(ask "Database name" "gitea")"
        DB_USER="$(ask "DB username" "gitea")"
        read -rsp "$(printf "${C_ACC}?${C_RESET} DB password: ")" DB_PASS; echo
        sudo apt-get update -y && sudo apt-get install -y mariadb-client
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
        msg_ok "MariaDB CLIENT installed. Template: $HOME/.config/client-app.ini"
        pause
        ;;
      3)
        clear; banner "MariaDB Uninstall" "server/client and data"
        local ans; ans="$(ask "Proceed? (yes/no)" "no")"
        if [[ "${ans}" =~ ^y(es)?$ ]]; then
          msg_info "Stopping MariaDB..."; sudo systemctl stop mariadb || true
          msg_info "Removing packages..."; sudo apt-get purge -y mariadb-server mariadb-client mariadb-common || true
          sudo apt-get autoremove -y || true; sudo apt-get autoclean -y || true
          msg_info "Removing configs/data..."; sudo rm -rf /etc/mysql /var/lib/mysql "$HOME/.config/client-app.ini"
          msg_ok "MariaDB and client configs uninstalled."
        else echo "Aborted."; fi
        pause
        ;;
      4)
        clear; banner "Test Server Connection"
        local DB_HOST DB_USER DB_PASS DB_NAME
        DB_HOST="$(ask "DB host (default 127.0.0.1)" "127.0.0.1")"
        DB_USER="$(ask "DB user" "gitea")"
        read -rsp "$(printf "${C_ACC}?${C_RESET} DB password: ")" DB_PASS; echo
        DB_NAME="$(ask "DB name" "gitea")"
        if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
          msg_ok "Server test OK."
        else msg_err "Server test FAILED."; fi
        pause
        ;;
      5)
        clear; banner "Test Client Connection"
        local DB_HOST DB_USER DB_PASS DB_NAME
        DB_HOST="$(ask "DB host/IP" "192.168.0.130")"
        DB_USER="$(ask "DB user" "gitea")"
        read -rsp "$(printf "${C_ACC}?${C_RESET} DB password: ")" DB_PASS; echo
        DB_NAME="$(ask "DB name" "gitea")"
        if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
          msg_ok "Client test OK."
        else msg_err "Client test FAILED."; fi
        pause
        ;;
      b|B) break ;;
      *) echo "Invalid choice";;
    esac
  done
}

# ==================== 9) HTTPS REVERSE PROXY (NGINX + LET'S ENCRYPT) ====================
https_proxy_menu(){
  while true; do
    clear; banner "HTTPS Reverse Proxy" "Nginx + Certbot (Let's Encrypt)"
    echo "${C_BOX}┌──────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo "${C_BOX}│${C_RESET} ${C_BOLD}1)${C_RESET} Install & configure Nginx proxy for Gitea + obtain TLS cert                "
    echo "${C_BOX}│${CRESET} ${C_BOLD}2)${CRESET} Force cert renewal (dry-run)                                                "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}3)${CRESET} Show Nginx status / test config                                            "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}4)${CRESET} Uninstall proxy config (keeps Gitea)                                         "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}b)${CRESET} Back                                                                  "
    echo "${C_BOX}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    read -rp "$(printf "${C_ACC}> ${C_RESET}")" pick
    case "$pick" in
      1)
        clear; banner "HTTPS Setup" "Nginx reverse proxy + Let's Encrypt"
        local DOMAIN EMAIL GITEA_INTERNAL_PORT
        DOMAIN="$(ask "Your domain/No-IP hostname (e.g. myhost.ddns.net)" "myhost.ddns.net")"
        EMAIL="$(ask "Email for Let's Encrypt notices" "you@example.com")"
        GITEA_INTERNAL_PORT="$(ask "Gitea internal port" "3000")"

        msg_info "Installing Nginx + Certbot plugin..."
        sudo apt-get update -y
        sudo apt-get install -y nginx certbot python3-certbot-nginx

        msg_info "Configuring Gitea to listen only on localhost:${GITEA_INTERNAL_PORT} and set https ROOT_URL..."
        # Update /etc/gitea/app.ini safely
        sudo mkdir -p /etc/gitea /var/lib/gitea/custom/conf
        if [[ -f /etc/gitea/app.ini ]]; then
          sudo awk -v port="$GITEA_INTERNAL_PORT" -v domain="$DOMAIN" '
            BEGIN{srv=0;act=0}
            /^\[server\]/{srv=1;act=0;print;next}
            /^\[actions\]/{srv=0;act=1;print;next}
            /^\[/{srv=0;act=0;print;next}
            {
              if(srv==1){
                if($0 ~ /^HTTP_ADDR[ \t]*=/){print "HTTP_ADDR = 127.0.0.1"; next}
                if($0 ~ /^HTTP_PORT[ \t]*=/){print "HTTP_PORT = " port; next}
                if($0 ~ /^PROTOCOL[ \t]*=/){print "PROTOCOL = http"; next}
                if($0 ~ /^ROOT_URL[ \t]*=/){print "ROOT_URL = https://" domain "/"; next}
              }
              print
            }
          ' /etc/gitea/app.ini | sudo tee /etc/gitea/app.ini.tmp >/dev/null
          sudo mv /etc/gitea/app.ini.tmp /etc/gitea/app.ini
        else
          sudo tee /etc/gitea/app.ini >/dev/null <<EOF
[server]
PROTOCOL  = http
HTTP_ADDR = 127.0.0.1
HTTP_PORT = ${GITEA_INTERNAL_PORT}
ROOT_URL  = https://${DOMAIN}/

[actions]
ENABLED = true
EOF
        fi
        sudo cp /etc/gitea/app.ini /var/lib/gitea/custom/conf/app.ini || true
        sudo chown git:git /var/lib/gitea/custom/conf/app.ini 2>/dev/null || true
        sudo chmod 640 /var/lib/gitea/custom/conf/app.ini 2>/dev/null || true
        sudo systemctl restart gitea

        msg_info "Creating Nginx site config for ${DOMAIN}..."
        sudo tee /etc/nginx/sites-available/gitea >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    access_log /var/log/nginx/gitea_access.log;
    error_log  /var/log/nginx/gitea_error.log;

    # ACME challenge location (Certbot)
    location ~ /.well-known/acme-challenge/ { allow all; }

    location / {
        proxy_pass         http://127.0.0.1:${GITEA_INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        # websockets / SSE
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}
EOF
        sudo ln -sf /etc/nginx/sites-available/gitea /etc/nginx/sites-enabled/gitea
        sudo nginx -t && sudo systemctl reload nginx

        msg_info "Requesting Let's Encrypt certificate (HTTP-01)..."
        if sudo certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --redirect; then
          msg_ok "Certificate obtained and HTTPS redirect enabled."
        else
          msg_err "Certbot failed. Ensure port 80 is reachable from the internet to this host."
        fi

        print_hr
        echo "Open: ${C_LINK}https://${DOMAIN}/${C_RESET}"
        echo "Ports needed open/forwarded: ${C_BOLD}80/tcp${C_RESET} (for initial/renewal), ${C_BOLD}443/tcp${C_RESET} (HTTPS)."
        print_hr
        pause
        ;;
      2)
        msg_info "Certbot dry-run renewal..."
        if sudo certbot renew --dry-run; then msg_ok "Dry-run succeeded."; else msg_err "Dry-run failed."; fi
        pause
        ;;
      3)
        section "Nginx status & config test"
        _systemctl_status nginx
        echo; msg_info "nginx -t output:"; sudo nginx -t || true
        pause
        ;;
      4)
        msg_warn "This removes the Nginx gitea site and reloads Nginx (Gitea kept)."
        local sure; sure="$(ask "Proceed? (yes/no)" "no")"
        if [[ "$sure" =~ ^y(es)?$ ]]; then
          sudo rm -f /etc/nginx/sites-enabled/gitea /etc/nginx/sites-available/gitea
          sudo nginx -t && sudo systemctl reload nginx || true
          msg_ok "Proxy config removed."
        else echo "Aborted."; fi
        pause
        ;;
      b|B) break ;;
      *) echo "Invalid choice";;
    esac
  done
}

# ==================== MAIN MENU ====================
main_menu(){
  while true; do
    clear; banner "Main Menu" "Dark Blue UI • bash only • zero extra deps"
    echo "${C_BOX}┌──────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo "${C_BOX}│${C_RESET} ${C_BOLD}0)${C_RESET} Install Gitea server & configs                                              "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}1)${C_RESET} Install runner                                                                "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}2)${C_RESET} Runner hook to Gitea (re-register)                                            "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}3)${CRESET} Show smoke-test workflow snippet                                                "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}4)${C_RESET} Ops tools (reconfigure/update/logs/net + runner→MySQL test)                "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}5)${CRESET} DNS (No-IP via ddclient)                                                       "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}6)${C_RESET} Uninstall Gitea server                                                        "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}7)${C_RESET} Uninstall runner                                                              "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}8)${CRESET} MySQL/MariaDB setup (Server/Client/Uninstall/Tests)                         "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}9)${C_RESET} HTTPS reverse proxy (Nginx + Let's Encrypt)                                   "
    echo "${C_BOX}│${C_RESET} ${C_BOLD}q)${CRESET} Quit                                                                          "
    echo "${C_BOX}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    read -rp "$(printf "${C_ACC}> ${C_RESET}")" choice
    case "$choice" in
      0) install_gitea_server ;;
      1) install_runner ;;
      2) runner_hook ;;
      3) print_workflow_snippet ;;
      4) ops_tools_menu ;;
      5) dns_noip_menu ;;
      6) uninstall_gitea_only ;;
      7) uninstall_runner_only ;;
      8) mysql_menu ;;
      9) https_proxy_menu ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

main_menu
