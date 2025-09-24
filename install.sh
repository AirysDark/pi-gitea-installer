#!/usr/bin/env bash

set -e

echo "[*] Updating system..."
sudo apt update && sudo apt upgrade -y

echo "[*] Installing build tools..."
sudo apt install -y git build-essential sqlite3 nginx fcgiwrap

echo "[*] Downloading Gitea..."
wget -O gitea https://dl.gitea.io/gitea/1.21.11/gitea-1.21.11-linux-arm64
chmod +x gitea
sudo mv gitea /usr/local/bin/

echo "[*] Creating Gitea user and folders..."
sudo adduser --system --group --disabled-password --home /home/git git
sudo mkdir -p /var/lib/gitea/{custom,data,log}
sudo chown -R git:git /var/lib/gitea/
sudo chmod -R 750 /var/lib/gitea/

echo "[*] Writing Gitea systemd service..."
sudo tee /etc/systemd/system/gitea.service > /dev/null <<EOF
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

echo "[*] Starting Gitea service..."
sudo systemctl daemon-reexec
sudo systemctl enable gitea
sudo systemctl start gitea

echo "[*] Installing Arduino CLI..."
curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh
sudo mv bin/arduino-cli /usr/local/bin/
arduino-cli config init

echo "[*] Creating bare Git repo..."
sudo mkdir -p /srv/git
cd /srv/git
sudo git init --bare myrepo.git

echo "[✔] Installation complete."
echo "→ Visit Gitea at: http://<your-raspi-ip>:3000"
echo "→ Edit hostname and enable interfaces manually with: sudo raspi-config"
