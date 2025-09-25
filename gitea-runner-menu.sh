#!/usr/bin/env bash
# gitea-runner-menu.sh
# Menu-driven helper for Gitea Actions setup (server) and act_runner install (runner).
# Adds a "0) First install" path that generates a token (via CLI if available) then installs the runner.
# Tested on Debian/Raspberry Pi OS-style systems.
set -euo pipefail

# --------- Globals used for prefill between flows ----------
PREFILL_INSTANCE_URL=""
PREFILL_TOKEN=""

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

pause() {
  read -rp "Press Enter to continue..." || true
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

print_hr() { printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '-'; }

status_ok()  { echo -e "\e[32m$*\e[0m"; }
status_info(){ echo -e "\e[36m$*\e[0m"; }
status_warn(){ echo -e "\e[33m$*\e[0m"; }
status_err() { echo -e "\e[31m$*\e[0m"; }

# --------- Token generator (CLI) ----------
# Sets REG_TOKEN_OUT global if successful.
REG_TOKEN_OUT=""
gitea_generate_token_cli() {
  local cfg_path="$1"
  REG_TOKEN_OUT=""
  if ! have_cmd gitea; then
    status_warn "Gitea CLI not found on PATH; cannot auto-generate token."
    return 1
  fi
  status_info "Generating runner registration token via CLI..."
  if REG_TOKEN_OUT="$(sudo gitea --config "$cfg_path" actions generate-runner-token 2>/dev/null)"; then
    status_ok "Registration Token (save this safely):"
    echo "$REG_TOKEN_OUT"
    return 0
  else
    status_err "Failed to generate token via CLI. Check gitea binary/permissions."
    return 1
  fi
}

# --------- Gitea (server) flow ----------
gitea_server_flow() {
  print_hr
  echo "Gitea server setup (enable Actions, confirm ROOT_URL, optional token gen)"
  print_hr

  # Detect config path (native installs typically /etc/gitea/app.ini or /etc/gitea/conf/app.ini)
  local default_cfg=""
  if [[ -f /etc/gitea/app.ini ]]; then
    default_cfg="/etc/gitea/app.ini"
  elif [[ -f /etc/gitea/conf/app.ini ]]; then
    default_cfg="/etc/gitea/conf/app.ini"
  elif [[ -f /var/lib/gitea/custom/conf/app.ini ]]; then
    default_cfg="/var/lib/gitea/custom/conf/app.ini"
  fi

  local cfg_path
  cfg_path="$(ask "Path to app.ini" "${default_cfg:-/etc/gitea/app.ini}")"
  sudo mkdir -p "$(dirname "$cfg_path")"
  sudo touch "$cfg_path"

  # Ask networking basics
  local default_ip="192.168.0.140"
  local ip port proto
  ip="$(ask "Gitea host/IP for ROOT_URL" "$default_ip")"
  port="$(ask "Gitea HTTP port" "3000")"
  proto="$(ask "Protocol" "http")"

  local root_url="${proto}://${ip}:${port}/"
  PREFILL_INSTANCE_URL="$root_url"  # keep for runner prefill

  status_info "Writing/ensuring minimal settings in ${cfg_path} ..."
  # Ensure [server] and [actions] sections exist
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

  # Ensure required keys exist even if section was blank
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

  # Restart (native or docker)
  echo
  status_info "Restart Gitea"
  local run_mode
  run_mode="$(ask "Is Gitea running in Docker? (yes/no)" "no")"
  if [[ "$run_mode" =~ ^y(es)?$ ]]; then
    local docker_name
    docker_name="$(ask "Docker container name" "gitea")"
    if have_cmd docker; then
      sudo docker restart "$docker_name"
    else
      status_err "docker not found. Please restart your container manually."
    fi
  else
    if have_cmd systemctl; then
      sudo systemctl restart gitea || status_warn "Could not restart gitea via systemctl; start it manually if needed."
    else
      status_warn "systemctl not available; restart your service manually."
    fi
  fi

  # Health check
  echo
  status_info "Checking ${root_url} ..."
  if curl -sfL "${root_url}" -o /dev/null; then
    status_ok "Gitea OK ✅"
  else
    status_err "Gitea not reachable ❌  (check firewall/ports/service logs)"
  fi

  # Optional: generate a registration token using CLI (instance-level)
  echo
  if have_cmd gitea; then
    local gen
    gen="$(ask "Generate a runner registration token now using Gitea CLI? (yes/no)" "yes")"
    if [[ "$gen" =~ ^y(es)?$ ]]; then
      if gitea_generate_token_cli "$cfg_path"; then
        PREFILL_TOKEN="$REG_TOKEN_OUT"
        echo
        status_info "Saved token for prefill in this session."
      else
        status_warn "Token not generated; you can still paste one in the Runner step."
      fi
    fi
  else
    status_warn "Gitea CLI not found; skip token generation. Get a token in the web UI."
  fi

  pause
}

# --------- Runner flow ----------
runner_flow() {
  print_hr
  echo "Runner install & register (this host)"
  print_hr

  local instance_url reg_token runner_name runner_labels
  local default_url="${PREFILL_INSTANCE_URL:-http://192.168.0.140:3000/}"
  instance_url="$(ask "Gitea INSTANCE_URL (e.g., http://192.168.0.140:3000/)" "$default_url")"

  # Try prefilled token first
  if [[ -n "${PREFILL_TOKEN}" ]]; then
    status_info "Using prefilled registration token from previous step."
    reg_token="$PREFILL_TOKEN"
  else
    reg_token="$(ask "Registration token (paste from Gitea or CLI)" "")"
  fi

  if [[ -z "$reg_token" ]]; then
    status_warn "No token provided. You can go back to Gitea menu to generate one."
    pause
    return 0
  fi
  runner_name="$(ask "Runner name" "runner-pi")"
  runner_labels="$(ask "Runner labels (comma-separated)" "self-hosted,linux,arm64,pi,${runner_name}")"

  print_hr
  status_info "Installing & registering runner ..."
  export INSTANCE_URL="${instance_url}"
  export REG_TOKEN="${reg_token}"
  export RUNNER_NAME="${runner_name}"
  export RUNNER_LABELS="${runner_labels}"

  # Use your installer one-liner
  bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)

  print_hr
  status_info "Verifying service status ..."
  if have_cmd systemctl; then
    (sudo systemctl status gitea-runner --no-pager || systemctl --user status gitea-runner --no-pager) || true
    echo
    status_info "Recent logs:"
    (sudo journalctl -u gitea-runner -n 200 --no-pager 2>/dev/null || true)
  else
    status_warn "systemctl not available; verify your runner process manually."
  fi

  status_info "If registration succeeded, you should see \"${runner_name}\" online in the Gitea UI under Runners."
  pause
}

# --------- First install (generate token then install runner) ----------
first_install_flow() {
  print_hr
  echo "First install: configure Gitea + generate token (CLI) + install runner on this host"
  print_hr
  gitea_server_flow   # sets PREFILL_INSTANCE_URL; may set PREFILL_TOKEN if CLI token gen succeeds
  runner_flow         # uses PREFILL_* to prefill answers
}

# --------- Bonus: print smoke-test workflow ----------
print_workflow_snippet() {
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
  echo
  status_info "Copy the above into .gitea/workflows/ci.yml in any repo and push to main."
  pause
}

# --------- Main menu ----------
main_menu() {
  while true; do
    clear || true
    echo "========== Gitea / Runner Setup =========="
    echo "0) First install: Gitea config + generate token (CLI) + install runner"
    echo "1) Gitea (server): enable Actions, confirm ROOT_URL, restart, optional token"
    echo "2) Runner: install & register this host as a runner"
    echo "3) Show smoke-test workflow snippet"
    echo "q) Quit"
    echo "------------------------------------------"
    choice="$(ask "Choose an option" "")"
    case "$choice" in
      0) first_install_flow ;;
      1) gitea_server_flow ;;
      2) runner_flow ;;
      3) print_workflow_snippet ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; sleep 1 ;;
    esac
  done
}

main_menu
