#!/usr/bin/env bash
set -euo pipefail

# ================== CONFIG ==================
INSTANCE_URL="${INSTANCE_URL:-http://192.168.0.140:3000/}"   # override with env
REG_TOKEN="${REG_TOKEN:-}"                                   # must pass in env
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"                   # default = hostname
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,arm64,pi}" # override if needed
RUNNER_VERSION="${RUNNER_VERSION:-0.2.10}"                  # default version
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
SERVICE_USER="${SERVICE_USER:-$USER}"
# ============================================

if [[ -z "$REG_TOKEN" ]]; then
  echo "❌ ERROR: REG_TOKEN not set"
  echo "Usage: REG_TOKEN=xxxx INSTANCE_URL=http://192.168.x.x:3000 bash <(curl -fsSL ...)"
  exit 1
fi

echo "==> Updating system"
sudo apt-get update -y
sudo apt-get install -y curl unzip

echo "==> Installing act_runner $RUNNER_VERSION"
curl -L "https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-arm64" -o /tmp/act_runner
chmod +x /tmp/act_runner
sudo mv /tmp/act_runner "$INSTALL_DIR/act_runner"

echo "==> Registering runner"
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

echo "✅ Done! Runner installed and started."
echo "Check logs with: journalctl -u gitea-runner -f"
