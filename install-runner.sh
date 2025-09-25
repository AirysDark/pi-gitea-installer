#!/usr/bin/env bash
set -euo pipefail

### CONFIG — edit these before running ###
INSTANCE_URL="http://192.168.0.140:3000/"       # your Gitea instance
REG_TOKEN="PASTE_YOUR_RUNNER_TOKEN_HERE"        # get from Gitea UI (Admin → Actions → Runners)
RUNNER_NAME="$(hostname)"                       # default: use Pi hostname
RUNNER_LABELS="self-hosted,linux,arm64,pi"      # labels you want
RUNNER_VERSION="0.2.10"                         # act_runner version
INSTALL_DIR="/usr/local/bin"
SERVICE_USER="$USER"                            # current user
##############################################

echo "==> Updating system"
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y curl unzip

echo "==> Installing act_runner $RUNNER_VERSION"
curl -L "https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-arm64" -o /tmp/act_runner
chmod +x /tmp/act_runner
sudo mv /tmp/act_runner "$INSTALL_DIR/act_runner"

echo "==> Registering runner with Gitea"
mkdir -p "$HOME/.config/act_runner"
"$INSTALL_DIR/act_runner" register \
  --instance "$INSTANCE_URL" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS"

echo "==> Creating systemd service"
sudo tee /etc/systemd/system/gitea-runner.service >/dev/null <<EOF
[Unit]
Description=Gitea Actions Runner
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=HOME=$HOME
Environment=XDG_CONFIG_HOME=$HOME/.config
WorkingDirectory=$HOME
ExecStart=$INSTALL_DIR/act_runner daemon
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

echo "==> Enabling and starting service"
sudo systemctl daemon-reload
sudo systemctl enable gitea-runner
sudo systemctl start gitea-runner

echo "==> Done!"
echo "Check logs with: journalctl -u gitea-runner -f"
