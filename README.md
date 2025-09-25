# 🛠️ Pi Gitea Installer

This script sets up a self-hosted **Gitea Git server** on a **Raspberry Pi** (ARM64), along with:
- Arduino CLI
- Bare Git repo
- NGINX + fcgiwrap for lightweight web hosting

---

## ✅ One-Line Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install.sh)
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)
```

```bash
INSTANCE_URL="http://192.168.0.140:3000/" \
REG_TOKEN="1xYv8rhioHFyLtzLSZOZHadCxhYovuxfkBFUaMJi" \
bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)
```

---

## 🚀 What It Installs

### ✔️ System Setup
- Updates and upgrades Raspbian packages
- Installs build tools (`git`, `build-essential`, `sqlite3`)
- Installs `nginx` and `fcgiwrap`

### ✔️ Gitea (GitHub Clone)
- Downloads Gitea v1.21.11 ARM64 binary
- Sets up:
  - Gitea system user
  - Data and config directories
  - `systemd` service to auto-start Gitea at boot
- Runs on port `3000` by default  
  → Visit: `http://<raspberry-pi-ip>:3000`

### ✔️ Arduino CLI
- Installs official `arduino-cli`
- Initializes `arduino-cli.yaml` config

### ✔️ Bare Git Repo
Creates an empty Git repo you can push to:

```bash
/srv/git/myrepo.git
```

You can clone/push to it via:
```bash
git clone git@<your-raspberry-pi-ip>:/srv/git/myrepo.git
```

---

## 🧰 Post-Install Manual Steps

> These are not automated (yet), but recommended:

- Run `sudo raspi-config` to:
  - Set hostname
  - Enable SSH, SPI, I2C, etc.
- Create and edit Gitea `app.ini` at:
  ```
  /var/lib/gitea/custom/conf/app.ini
  ```
- Optionally configure NGINX to reverse-proxy Gitea on port 80

---

## 📂 File Structure

```
pi-gitea-installer/
├── install.sh         # Main installation script
└── README.md          # You're here
```

---

## 🧪 Tested On

- Raspberry Pi 3 / 4 (64-bit Raspbian Lite)
- Gitea 1.21.11 (ARM64)
- Arduino CLI (latest from GitHub)

---

## 🧑‍💻 Author

**AirysDark**  
🔗 [github.com/AirysDark](https://github.com/AirysDark)

---

## 📄 License

MIT
