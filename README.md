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

0) On the Gitea Pi — ensure Actions are enabled

If you’re running Gitea already (you are), make sure Actions are on and the URLs are correct.

# Edit app.ini (native install)
sudo mkdir -p /etc/gitea
sudo nano /etc/gitea/app.ini

Add/confirm these sections (adjust IP/port if different):

[server]
PROTOCOL  = http
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
ROOT_URL  = http://192.168.0.140:3000/

[actions]
ENABLED = true

Then restart Gitea (native):

sudo systemctl restart gitea

If you run Gitea in Docker, set the same values via env or file and:

docker restart gitea

Check it’s alive:

curl -sfL http://192.168.0.140:3000/ -o /dev/null && echo "Gitea OK ✅" || echo "Gitea not reachable ❌"


---

1) Grab a registration token (one per runner)

In the Gitea web UI:

Site Admin → Actions → Runners → Register new runner (global),
or Repo → Settings → Runners → Register new runner (scoped). Copy the registration token; you’ll paste it below.



---

2) Install a runner on the Gitea Pi

Use your existing installer (simple and works on Pi):

# Replace with YOUR token
INSTANCE_URL="http://192.168.0.140:3000/" \
REG_TOKEN="PASTE_TOKEN_FOR_GITEA_PI" \
RUNNER_NAME="gitea-pi" \
RUNNER_LABELS="self-hosted,linux,arm64,pi,gitea-pi" \
bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)

Verify it’s up:

sudo systemctl status gitea-runner --no-pager || systemctl --user status gitea-runner --no-pager
sudo journalctl -u gitea-runner -n 200 --no-pager 2>/dev/null || true

You should now see “gitea-pi” as online under Runners in the Gitea UI.


---

3) Install a runner on the Runner Pi

Same deal, different name/labels and token (you can reuse the same global token or generate another):

# Replace with YOUR token
INSTANCE_URL="http://192.168.0.140:3000/" \
REG_TOKEN="PASTE_TOKEN_FOR_RUNNER_PI" \
RUNNER_NAME="runner-pi" \
RUNNER_LABELS="self-hosted,linux,arm64,pi,runner-pi" \
bash <(curl -fsSL https://raw.githubusercontent.com/AirysDark/pi-gitea-installer/main/install-runner.sh)

Verify:

sudo systemctl status gitea-runner --no-pager || systemctl --user status gitea-runner --no-pager
sudo journalctl -u gitea-runner -n 200 --no-pager 2>/dev/null || true

You should now see two online runners in the Gitea UI: gitea-pi and runner-pi.


---

4) Smoke test with a workflow

In any repo, create .gitea/workflows/ci.yml:

name: CI
on:
  push:
    branches: [ main ]

jobs:
  hello:
    runs-on: [ self-hosted ]   # or: [ self-hosted, runner-pi ] to target only Runner Pi by label
    steps:
      - name: Print env
        run: |
          echo "Hello from $HOSTNAME"
          uname -a
          lscpu | sed -n '1,10p' || true

Commit & push to main.
Check the repo’s Actions tab — the job should pick up on one of your Pis.


---

Useful ops commands (both Pis)

Reconfigure the runner (change name/labels/URL):

sudo systemctl stop gitea-runner || true
sudo rm -rf /var/lib/gitea-runner/* ~/.config/gitea-runner/* 2>/dev/null || true
# re-run the installer with new envs

Update the runner binary (if my script pinned a version):

sudo systemctl stop gitea-runner || true
sudo /usr/local/bin/gitea-runner --version || true
# re-run the installer line; it will refresh to the version it uses
sudo systemctl start gitea-runner

Network sanity checks from Runner Pi → Gitea Pi:

curl -I http://192.168.0.140:3000/ || echo "cannot reach :3000"
nc -vz 192.168.0.140 3000


---

Alternative setups you might want later

Lock a job to a specific Pi: use runs-on: [ self-hosted, gitea-pi ] or runner-pi (matches by labels).

Concurrency limits: add labels per “capability” (e.g., build, flash, gpu) and target them in workflows.

Behind HTTPS or reverse proxy: just set INSTANCE_URL="https://your.lan.name/" and ensure ROOT_URL matches.



---

TL;DR action plan

1. Ensure Actions are enabled on the Gitea Pi and ROOT_URL is correct.


2. Generate a runner token in Gitea UI.


3. Run the installer once on Gitea Pi (name: gitea-pi).


4. Run the installer once on Runner Pi (name: runner-pi).


5. Add a simple .gitea/workflows/ci.yml and push; watch both go green.



If anything throws an error, paste the last 30–50 lines of journalctl -u gitea-runner from the failing box and I’ll zero in on it.
