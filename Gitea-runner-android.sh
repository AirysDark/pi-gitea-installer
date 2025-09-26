#!/usr/bin/env bash
# gitea-runner-menu-termux.sh
# All-in-one helper for Gitea server/runner + MariaDB + No-IP (DDNS) on Termux (Android)
# Termux specifics: no systemd; uses termux-services (runit). Binaries in $PREFIX/bin.

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SV_DIR="$PREFIX/var/service"
BIN_DIR="$PREFIX/bin"
CFG_DIR="$HOME/.config"
LOG_DIR="$HOME/.local/var/log"
mkdir -p "$CFG_DIR" "$LOG_DIR"

# ---------- Helpers ----------
ask() { local p="${1:-}" d="${2-}" r; if [[ -n "$d" ]]; then read -rp "$p [$d]: " r || true; echo "${r:-$d}"; else read -rp "$p: " r || true; echo "$r"; fi; }
pause(){ read -rp "Press Enter to continue..." || true; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
print_hr(){ printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '-'; }
ok(){ echo -e "\e[32m$*\e[0m"; } info(){ echo -e "\e[36m$*\e[0m"; } warn(){ echo -e "\e[33m$*\e[0m"; } err(){ echo -e "\e[31m$*\e[0m"; }

ensure_termux_services(){
  if ! have_cmd sv; then
    info "Installing termux-services..."
    pkg update -y && pkg install -y termux-services
    # Start the service supervisor (first time)
    sv up || true
  fi
}

ensure_net_tools(){
  pkg update -y >/dev/null 2>&1 || true
  # nc is provided by 'netcat' package in termux
  pkg install -y curl wget git coreutils netcat >/dev/null 2>&1 || true
}

tail_log(){
  # runit logs (multilog) live under service/log/main/current; else app logs in $LOG_DIR
  local f="$1"
  if [[ -f "$f" ]]; then
    tail -n "${2:-200}" "$f" || true
  else
    echo "(no log file at $f)"
  fi
}

# ---------- 0) Install Gitea server (SQLite, termux-service) ----------
install_gitea_server(){
  print_hr; echo "Install Gitea server (SQLite, Termux)"; print_hr
  ensure_termux_services; ensure_net_tools
  local gver bin="$BIN_DIR/gitea"
  gver="$(ask "Gitea version" "1.22.3")"

  if ! have_cmd gitea; then
    info "Installing gitea $gver ..."
    wget -O "$bin" "https://dl.gitea.io/gitea/${gver}/gitea-${gver}-linux-arm64"
    chmod +x "$bin"
  else
    info "Gitea already installed at $(command -v gitea)"
  fi

  # Minimal dirs & config for SQLite
  local GROOT="$HOME/gitea"
  mkdir -p "$GROOT"/{custom,data,log}
  local ip port proto root_url
  ip="$(ask "Gitea bind IP (0.0.0.0 for LAN)" "0.0.0.0")"
  port="$(ask "Gitea port" "3000")"
  proto="$(ask "Protocol for ROOT_URL" "http")"
  local host_for_root
  host_for_root="$(ask "Public hostname/IP for ROOT_URL" "127.0.0.1")"
  root_url="${proto}://${host_for_root}:${port}/"

  cat > "$GROOT/app.ini" <<EOF
[server]
PROTOCOL  = http
HTTP_ADDR = ${ip}
HTTP_PORT = ${port}
ROOT_URL  = ${root_url}

[actions]
ENABLED = true

[database]
DB_TYPE = sqlite3
PATH = $HOME/gitea/data/gitea.db

[log]
MODE = file
LEVEL = info
ROOT_PATH = $HOME/gitea/log
EOF

  # Service: runit (termux-services)
  local SVC="gitea"
  mkdir -p "$SV_DIR/$SVC"
  cat > "$SV_DIR/$SVC/run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
export HOME="/data/data/com.termux/files/home"
exec 2>&1
exec gitea web --config "$HOME/gitea/app.ini"
EOF
  chmod +x "$SV_DIR/$SVC/run"

  # Optional logger with multilog
  mkdir -p "$SV_DIR/$SVC/log"
  cat > "$SV_DIR/$SVC/log/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt "$HOME/.local/var/log/${SVC}"
EOF
  chmod +x "$SV_DIR/$SVC/log/run"
  mkdir -p "$LOG_DIR/$SVC"

  info "Enabling & starting service..."
  sv-enable "$SVC" 2>/dev/null || true
  sv up "$SVC" || true
  sleep 2

  info "Health check ${root_url} ..."
  if curl -sfL "${root_url}" -o /dev/null; then
    ok "Gitea running at ${root_url} ✅"
  else
    warn "Could not reach ${root_url} yet. Check: sv status ${SVC} and logs in $LOG_DIR/${SVC}/current"
  fi
  pause
}

# ---------- 1) Install runner (act_runner, termux-service) ----------
install_runner(){
  print_hr; echo "Install runner (act_runner) — Termux"; print_hr
  ensure_termux_services; ensure_net_tools
  local rver inst reg name labels
  inst="$(ask "Gitea INSTANCE_URL" "http://127.0.0.1:3000/")"
  reg="$(ask "Registration token (from Gitea UI/CLI)" "")"
  [[ -n "$reg" ]] || { err "REG_TOKEN is required."; pause; return 1; }
  name="$(ask "Runner name" "termux-runner")"
  labels="$(ask "Runner labels" "self-hosted,linux,arm64,termux,${name}")"
  rver="$(ask "act_runner version" "0.2.10")"

  local bin="$BIN_DIR/act_runner"
  if ! have_cmd act_runner; then
    info "Installing act_runner $rver ..."
    wget -O "$bin" "https://gitea.com/gitea/act_runner/releases/download/v${rver}/act_runner-${rver}-linux-arm64"
    chmod +x "$bin"
  else
    info "act_runner already installed."
  fi

  mkdir -p "$HOME/.config/act_runner"
  info "Registering runner..."
  act_runner register --instance "$inst" --token "$reg" --name "$name" --labels "$labels"

  # Service
  local SVC="gitea-runner"
  mkdir -p "$SV_DIR/$SVC"
  cat > "$SV_DIR/$SVC/run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
export HOME="/data/data/com.termux/files/home"
export XDG_CONFIG_HOME="$HOME/.config"
exec 2>&1
exec act_runner daemon
EOF
  chmod +x "$SV_DIR/$SVC/run"

  mkdir -p "$SV_DIR/$SVC/log"
  cat > "$SV_DIR/$SVC/log/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt "$HOME/.local/var/log/${SVC}"
EOF
  chmod +x "$SV_DIR/$SVC/log/run"
  mkdir -p "$LOG_DIR/$SVC"

  info "Enabling & starting runner..."
  sv-enable "$SVC" 2>/dev/null || true
  sv up "$SVC" || true
  sleep 2
  ok "Runner installed & started ✅"
  echo "Check status: sv status ${SVC}"
  echo "Logs: tail -f $LOG_DIR/${SVC}/current"
  pause
}

# ---------- 2) Runner hook to Gitea (re-register) ----------
runner_hook(){
  print_hr; echo "Hook runner to Gitea (re-register)"; print_hr
  have_cmd act_runner || { err "act_runner not installed. Use option 1 first."; pause; return 1; }

  local inst reg name labels
  inst="$(ask "Gitea INSTANCE_URL" "http://127.0.0.1:3000/")"
  reg="$(ask "Registration token" "")"
  name="$(ask "Runner name" "termux-runner")"
  labels="$(ask "Runner labels" "self-hosted,linux,arm64,termux,${name}")"
  [[ -n "$reg" ]] || { err "REG_TOKEN is required."; pause; return 1; }

  info "Stopping runner..."
  sv down gitea-runner 2>/dev/null || true
  rm -rf "$HOME/.config/act_runner" 2>/dev/null || true

  info "Re-registering..."
  act_runner register --instance "$inst" --token "$reg" --name "$name" --labels "$labels"

  info "Starting runner..."
  sv up gitea-runner 2>/dev/null || true
  ok "Runner re-registered ✅"
  pause
}

# ---------- 3) Workflow snippet ----------
print_workflow_snippet(){
  print_hr; echo "CI workflow snippet (.gitea/workflows/ci.yml)"; print_hr
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

# ---------- 4) Ops tools ----------
ops_tools_menu(){
  while true; do
    clear || true
    echo "==== Ops Tools (Termux) ===="
    echo "1) Reconfigure runner (purge state & re-register)"
    echo "2) Update runner binary (download latest by version)"
    echo "3) Show runner service status"
    echo "4) Tail runner logs"
    echo "5) Network checks to Gitea (curl + nc)"
    echo "6) Runner → MySQL connectivity test (as current user)"
    echo "b) Back"
    read -rp "> " op
    case "$op" in
      1)
        sv down gitea-runner || true
        rm -rf "$HOME/.config/act_runner" || true
        local inst reg name labels
        inst="$(ask "INSTANCE_URL" "http://127.0.0.1:3000/")"
        reg="$(ask "Registration token" "")"
        name="$(ask 'Runner name' 'termux-runner')"
        labels="$(ask "Runner labels" "self-hosted,linux,arm64,termux,${name}")"
        if [[ -n "$reg" ]]; then
          act_runner register --instance "$inst" --token "$reg" --name "$name" --labels "$labels"
          sv up gitea-runner || true
          ok "Runner reconfigured ✅"
        else
          err "REG_TOKEN required."
        fi
        pause
        ;;
      2)
        local v; v="$(ask "act_runner version to install" "0.2.10")"
        wget -O "$BIN_DIR/act_runner" "https://gitea.com/gitea/act_runner/releases/download/v${v}/act_runner-${v}-linux-arm64"
        chmod +x "$BIN_DIR/act_runner"
        ok "Updated act_runner to v${v}"
        pause
        ;;
      3) sv status gitea-runner || true; pause ;;
      4) tail_log "$LOG_DIR/gitea-runner/current" 200; pause ;;
      5)
        local host port
        host="$(ask "Gitea host/IP" "127.0.0.1")"
        port="$(ask "Gitea port" "3000")"
        echo "curl check:"; curl -I "http://${host}:${port}/" || echo "cannot reach :${port}"
        echo "nc check:"; nc -vz "$host" "$port" || true
        pause
        ;;
      6)
        pkg install -y mariadb >/dev/null 2>&1 || true
        local dbh dbn dbu dbp
        dbh="$(ask "MySQL host/IP" "127.0.0.1")"
        dbn="$(ask "Database name" "gitea")"
        dbu="$(ask "DB username" "gitea")"
        read -rsp "DB password: " dbp; echo
        if mysql -h "$dbh" -u "$dbu" -p"$dbp" "$dbn" -e "SELECT 1;" >/dev/null 2>&1; then
          ok "Runner user can reach MySQL @ ${dbh} and auth to DB '${dbn}' ✅"
        else
          err "MySQL connectivity failed. Check port 3306, grants, password, bind-address."
        fi
        pause
        ;;
      b|B) break ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

# ---------- 5) SSHD Activate (Termux) ----------
sshd_activate_flow(){
  print_hr; echo "SSHD Activate (Termux)"; print_hr
  pkg install -y openssh >/dev/null 2>&1 || true
  local cfg="$PREFIX/etc/ssh/sshd_config"
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<'EOF'
PasswordAuthentication yes
# Termux environment (no root). PermitRootLogin is irrelevant.
ChallengeResponseAuthentication no
UsePAM no
Subsystem sftp internal-sftp
EOF
  # Set a password for the current Termux user (required for password auth)
  warn "Set a password for your Termux user to allow password login (this is local to Termux)."
  passwd || true
  # Start/enable service
  ensure_termux_services
  local SVC="sshd"
  sv-enable "$SVC" 2>/dev/null || true
  sv up "$SVC" || true
  ok "SSHD activated. Connect to: ssh $(whoami)@<phone-ip> -p 8022"
  pause
}

# ---------- 6) DNS (No-IP via curl + termux-job-scheduler) ----------
dns_noip_menu(){
  print_hr; echo "DNS (No-IP) via curl + job scheduler"; print_hr
  pkg install -y termux-api >/dev/null 2>&1 || true
  mkdir -p "$CFG_DIR"
  local conf="$CFG_DIR/noip.conf" updater="$BIN_DIR/noip-update"
  while true; do
    echo "1) Configure No-IP"
    echo "2) Force update now"
    echo "3) Schedule updates (every 15 min)"
    echo "4) Cancel scheduled updates"
    echo "5) Show current public IP"
    echo "b) Back"
    read -rp "> " c
    case "$c" in
      1)
        local user pass host
        user="$(ask "No-IP username/email" "")"
        read -rsp "No-IP password: " pass; echo
        host="$(ask "Hostname (e.g., myhost.ddns.net)" "")"
        [[ -n "$user" && -n "$pass" && -n "$host" ]] || { err "All fields required."; pause; continue; }
        cat > "$conf" <<EOF
NOIP_USER="$user"
NOIP_PASS="$pass"
NOIP_HOST="$host"
EOF
        cat > "$updater" <<'EOS'
#!/data/data/com.termux/files/usr/bin/sh
set -eu
CONF="$HOME/.config/noip.conf"
[ -f "$CONF" ] || exit 0
. "$CONF"
curl -s "https://dynupdate.no-ip.com/nic/update?hostname=${NOIP_HOST}" \
  -u "${NOIP_USER}:${NOIP_PASS}" \
  -A "TermuxNoIP/1.0" >/dev/null 2>&1 || true
EOS
        chmod +x "$updater"
        ok "Configured. Config: $conf  Updater: $updater"
        pause
        ;;
      2)
        [[ -x "$updater" ]] || { err "Configure first (option 1)."; pause; continue; }
        sh "$updater" && ok "Forced update sent." || warn "Update attempt finished (check credentials/hostname)."
        pause
        ;;
      3)
        [[ -x "$updater" ]] || { err "Configure first (option 1)."; pause; continue; }
        termux-job-scheduler --job-id 31 \
          --period-ms 900000 \
          --persisted true \
          --script "$updater"
        ok "Scheduled updates every 15 minutes (job id 31)."
        pause
        ;;
      4)
        termux-job-scheduler --cancel --job-id 31 || true
        ok "Cancelled scheduled updates (job id 31)."
        pause
        ;;
      5)
        curl -s https://api.ipify.org && echo
        pause
        ;;
      b|B) break ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

# ---------- 7) Uninstall Gitea (Termux) ----------
uninstall_gitea_only(){
  print_hr; warn "Uninstall Gitea (Termux)"; local sure; sure="$(ask "Proceed? (yes/no)" "no")"
  [[ "$sure" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; return 0; }
  sv down gitea 2>/dev/null || true
  rm -rf "$SV_DIR/gitea"
  rm -f "$BIN_DIR/gitea"
  rm -rf "$HOME/gitea"
  ok "Gitea removed."
  pause
}

# ---------- 8) Uninstall Runner (Termux) ----------
uninstall_runner_only(){
  print_hr; warn "Uninstall Runner (Termux)"; local sure; sure="$(ask "Proceed? (yes/no)" "no")"
  [[ "$sure" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; return 0; }
  sv down gitea-runner 2>/dev/null || true
  rm -rf "$SV_DIR/gitea-runner"
  rm -f "$BIN_DIR/act_runner"
  rm -rf "$HOME/.config/act_runner"
  ok "Runner removed."
  pause
}

# ---------- 9) MySQL/MariaDB setup (Server/Client/Uninstall/Test) ----------
mysql_menu(){
  print_hr; echo "MySQL/MariaDB (Termux)"; print_hr
  PS3="Choose mode: "
  select MODE in "Server" "Client" "Uninstall" "Test Server" "Test Client" "Back"; do
    case "${MODE:-}" in
      Server)
        pkg install -y mariadb >/dev/null 2>&1 || true
        # Init data dir if needed
        if [ ! -d "$PREFIX/var/lib/mysql/mysql" ]; then
          info "Initializing MariaDB data directory..."
          mysql_install_db
        fi
        # Service: mariadbd under runit
        local SVC="mariadbd"
        mkdir -p "$SV_DIR/$SVC"
        cat > "$SV_DIR/$SVC/run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
exec mysqld_safe --datadir=$PREFIX/var/lib/mysql
EOF
        sed -i "s|\$PREFIX|$PREFIX|g" "$SV_DIR/$SVC/run"
        chmod +x "$SV_DIR/$SVC/run"
        mkdir -p "$SV_DIR/$SVC/log"
        cat > "$SV_DIR/$SVC/log/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt "$HOME/.local/var/log/${SVC}"
EOF
        chmod +x "$SV_DIR/$SVC/log/run"
        mkdir -p "$LOG_DIR/$SVC"

        sv-enable "$SVC" 2>/dev/null || true
        sv up "$SVC" || true
        sleep 3

        local rootpw dbname dbuser dbpass gdomain
        rootpw="$(ask "Set MySQL root password" "changeme")"
        dbname="$(ask "Database name for Gitea" "gitea")"
        dbuser="$(ask "Gitea DB username" "gitea")"
        read -rsp "Gitea DB user password: " dbpass; echo
        gdomain="$(ask "Gitea domain/IP for app.ini ROOT_URL" "127.0.0.1")"

        info "Securing root and creating DB/user..."
        mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${rootpw}'; FLUSH PRIVILEGES;" || true
        mysql -u root -p"${rootpw}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'%' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'%';
FLUSH PRIVILEGES;
EOF

        # Write Gitea app.ini (switch DB to MySQL)
        if [[ -f "$HOME/gitea/app.ini" ]]; then
          awk -v host="$gdomain" '
            BEGIN{in_db=0}
            /^\[database\]/ {print; in_db=1; next}
            /^\[/{if(in_db){in_db=0}; print; next}
            {
              if(in_db==1){
                if($0 ~ /^DB_TYPE/)  {print "DB_TYPE  = mysql"; next}
                if($0 ~ /^PATH/)     {next}
                if($0 ~ /^HOST/)     {print "HOST     = 127.0.0.1:3306"; next}
                if($0 ~ /^NAME/)     {print "NAME     = '"${dbname}"'"; next}
                if($0 ~ /^USER/)     {print "USER     = '"${dbuser}"'"; next}
                if($0 ~ /^PASSWD/)   {print "PASSWD   = '"${dbpass}"'"; next}
              }
              print
            }' "$HOME/gitea/app.ini" > "$HOME/gitea/app.ini.tmp" && mv "$HOME/gitea/app.ini.tmp" "$HOME/gitea/app.ini"
          ok "Updated $HOME/gitea/app.ini for MySQL."
        else
          warn "Gitea app.ini not found; install Gitea first (option 0)."
        fi
        ok "MariaDB server up. Status: sv status ${SVC}"
        pause
        ;;
      Client)
        pkg install -y mariadb >/dev/null 2>&1 || true
        local host db user pass
        host="$(ask "MySQL server host/IP" "127.0.0.1")"
        db="$(ask "Database name" "gitea")"
        user="$(ask "Username" "gitea")"
        read -rsp "Password: " pass; echo
        mkdir -p "$CFG_DIR"
        cat > "$CFG_DIR/client-app.ini" <<EOF
[database]
DB_TYPE  = mysql
HOST     = ${host}:3306
NAME     = ${db}
USER     = ${user}
PASSWD   = ${pass}
SCHEMA   =
SSL_MODE = disable
EOF
        ok "Client config saved to $CFG_DIR/client-app.ini"
        pause
        ;;
      Uninstall)
        warn "This will stop/remove MariaDB & data under $PREFIX/var/lib/mysql."
        local ans; ans="$(ask "Proceed? (yes/no)" "no")"
        [[ "$ans" =~ ^y(es)?$ ]] || { echo "Aborted."; pause; continue; }
        sv down mariadbd 2>/dev/null || true
        rm -rf "$SV_DIR/mariadbd"
        rm -rf "$PREFIX/var/lib/mysql"
        # keep client tools unless you want them gone:
        ok "MariaDB server removed. Client tools remain (pkg uninstall mariadb to remove)."
        pause
        ;;
      "Test Server")
        pkg install -y mariadb >/dev/null 2>&1 || true
        local host user pass db
        host="$(ask "DB host (default 127.0.0.1)" "127.0.0.1")"
        user="$(ask "DB user" "gitea")"
        read -rsp "DB password: " pass; echo
        db="$(ask "DB name" "gitea")"
        if mysql -h "$host" -u "$user" -p"$pass" "$db" -e "SELECT 1;" >/dev/null 2>&1; then
          ok "Server test OK ✅"
        else
          err "Server test FAILED ❌"
        fi
        pause
        ;;
      "Test Client")
        pkg install -y mariadb >/dev/null 2>&1 || true
        local host user pass db
        host="$(ask "DB host/IP" "127.0.0.1")"
        user="$(ask "DB user" "gitea")"
        read -rsp "DB password: " pass; echo
        db="$(ask "DB name" "gitea")"
        if mysql -h "$host" -u "$user" -p"$pass" "$db" -e "SELECT 1;" >/dev/null 2>&1; then
          ok "Client test OK ✅"
        else
          err "Client test FAILED ❌"
        fi
        pause
        ;;
      Back) break ;;
      *) echo "Invalid choice";;
    esac
  done
}

# ---------- Main menu ----------
main_menu(){
  ensure_net_tools
  while true; do
    clear || true
    echo "===== Gitea / Runner (Termux) ====="
    echo "0) Install Gitea server (SQLite)"
    echo "1) Install runner (act_runner)"
    echo "2) Runner hook to Gitea (re-register)"
    echo "3) Show smoke-test workflow snippet"
    echo "4) Ops tools (reconfigure/update/logs/net + MySQL test)"
    echo "5) SSHD Activate (OpenSSH in Termux)"
    echo "6) DNS (No-IP via curl + scheduler)"
    echo "7) Uninstall Gitea server"
    echo "8) Uninstall runner"
    echo "9) MySQL/MariaDB (Server / Client / Uninstall / Tests)"
    echo "q) Quit"
    echo "-----------------------------------"
    choice="$(ask "Choose an option" "")"
    case "$choice" in
      0) install_gitea_server ;;
      1) install_runner ;;
      2) runner_hook ;;
      3) print_workflow_snippet ;;
      4) ops_tools_menu ;;
      5) sshd_activate_flow ;;
      6) dns_noip_menu ;;
      7) uninstall_gitea_only ;;
      8) uninstall_runner_only ;;
      9) mysql_menu ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

main_menu
