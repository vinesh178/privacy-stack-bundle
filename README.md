# 🔒 The Complete Privacy Stack

**One command. Eight self-hosted apps. Full data ownership.**

Replace Google Photos, Dropbox, Netflix, your password manager, and your DNS — all running on your own server.

| App | Replaces | Port |
|-----|----------|------|
| **Immich** | Google Photos | 2283 |
| **Paperless-ngx** | Dropbox + filing cabinet | 8000 |
| **Jellyfin** | Netflix / Plex | 8096 |
| **AdGuard Home** | Pi-hole / Cloud DNS | 3000 (+ 53) |
| **Vaultwarden** | 1Password / Bitwarden ($) | 8080 |
| **Uptime Kuma** | UptimeRobot | 3001 |
| **Homepage** | Your dashboard | 3002 |
| **Nginx Proxy Manager** | Reverse proxy + SSL | 81 |

Built and tested by someone who runs this exact stack daily with 20+ containers.

---

## Requirements

- **OS:** Ubuntu 22.04 or 24.04 LTS
- **RAM:** 4GB minimum, 8GB recommended
- **Disk:** 50GB minimum (Ubuntu + Docker overhead ~5GB, images ~10GB, plus room for data)
- **Ports:** 80, 443, 53 available
- **Domain:** Optional but recommended (for SSL)

Works on: VPS (Hetzner, DigitalOcean, Linode), home server, old laptop, mini PC.

---

## Quick Start

### One-Line Install

```bash
curl -sL https://raw.githubusercontent.com/vinesh178/privacy-stack-bundle/main/install.sh | sudo bash
```

That's it. The setup wizard walks you through everything — domain, which services you want, and all passwords are auto-generated. No manual config editing.

### Manual Install (Git)

```bash
git clone https://github.com/vinesh178/privacy-stack-bundle.git
cd privacy-stack-bundle
sudo bash scripts/setup.sh
```

### Manual Install (Zip)

If you downloaded a zip file (e.g., `privacy-stack-bundle.zip`):

```bash
# If unzip is available
unzip privacy-stack-bundle.zip
cd privacy-stack-bundle
sudo bash scripts/setup.sh

# If unzip is not installed (common on fresh VMs)
sudo apt-get install -y unzip
unzip privacy-stack-bundle.zip
cd privacy-stack-bundle
sudo bash scripts/setup.sh
```

> **Note:** The zip install does not include git history, so there is no built-in update path. To update later, re-download the zip and re-run setup, or switch to the git install method.

### Deploy to GCP (Terraform)

You can now provision an Ubuntu VM on Google Compute Engine and install the full bundle automatically from one command.

Prerequisites:
- Terraform installed locally
- Google Cloud project created
- Authenticated Application Default Credentials, for example:

```bash
gcloud auth application-default login
```

Wrapper script:

```bash
bash scripts/deploy-gcp.sh \
  --project-id your-gcp-project \
  --region us-central1 \
  --zone us-central1-a
```

With domain + SSL automation:

```bash
bash scripts/deploy-gcp.sh \
  --project-id your-gcp-project \
  --region us-central1 \
  --zone us-central1-a \
  --domain example.com \
  --acme-email you@example.com
```

What it does:
- Creates a dedicated VPC, subnet, firewall rules, static public IP, and Ubuntu 24.04 VM
- Uses the VM startup script to run the existing `install.sh` in non-interactive mode
- Auto-populates `.env` on the VM from Terraform variables, including profiles, domain, ACME email, and Tailscale auth key

Files:
- `terraform/gcp/` — Terraform config
- `terraform/gcp/terraform.tfvars.example` — example variables file
- `scripts/deploy-gcp.sh` — one-command wrapper for `terraform init` + `terraform apply`

If you prefer raw Terraform instead of the wrapper:

```bash
terraform -chdir=terraform/gcp init
terraform -chdir=terraform/gcp apply -auto-approve \
  -var="project_id=your-gcp-project" \
  -var="region=us-central1" \
  -var="zone=us-central1-a"
```

After apply finishes, Terraform prints the VM IP, access URLs, and helpful `gcloud compute ssh ...` commands to inspect the startup log.

### Non-Interactive (automation / scripts)

```bash
# Install with all defaults, no prompts
curl -sL https://raw.githubusercontent.com/vinesh178/privacy-stack-bundle/main/install.sh | NON_INTERACTIVE=1 sudo bash
```

### Choose Your Services

The setup wizard lets you pick which apps to install. Don't need a media server? Skip it. Only want photos and passwords? Just select those. Only selected services will run.

Available: Immich, Paperless-ngx, Jellyfin, AdGuard Home, Vaultwarden, Uptime Kuma, Homepage, Tailscale. Nginx Proxy Manager always runs (handles routing + SSL).

---

## After Installation

### 1. Nginx Proxy Manager (Auto-configured!)
Setup automatically:
- Changes the default password (saved to `credentials.txt`)
- Creates proxy hosts for all enabled services (if you provided a domain)
- Requests Let's Encrypt SSL certificates (if you provided an email)

**If you have a domain:** Point `*.yourdomain.com` (wildcard DNS) to your server IP, and everything works automatically.

**If you don't have a domain:** Access services directly by IP:port (e.g., `http://YOUR_IP:2283` for photos). No proxy setup needed.

### 2. Immich (Photos)
- Open `http://YOUR_IP:2283`
- Create admin account
- Install the Immich app on your phone (iOS/Android)
- Upload photos — they're now yours, not Google's

### 3. Paperless-ngx (Documents)
- Open `http://YOUR_IP:8000`
- Login with credentials from `credentials.txt` (generated during setup)
- Drag & drop PDFs into the consume folder or web UI
- OCR runs automatically

### 4. Jellyfin (Media)
- Open `http://YOUR_IP:8096`
- Create admin account
- Add media libraries pointing to `/media/movies`, `/media/tv`, `/media/music`
- Install Jellyfin app on your devices

### 5. AdGuard Home (DNS)
- Open `http://YOUR_IP:3000`
- Run initial setup wizard
- Point your devices DNS to your server's IP
- Ads blocked network-wide

### 6. Vaultwarden (Passwords)
- Open `http://YOUR_IP:8080`
- Create account
- Import from 1Password/LastPass/Chrome
- Install Bitwarden app/extension (compatible with Vaultwarden)

### 7. Uptime Kuma (Monitoring)
- Open `http://YOUR_IP:3001`
- Add monitors for each service
- Set up email/Telegram notifications

### 8. Homepage (Dashboard)
- Open `http://YOUR_IP:3002`
- Edit `configs/homepage/services.yaml` to update URLs
- Your one-stop dashboard for everything

---

## Maintenance

### Updates
```bash
# Pull latest images and restart
docker compose pull
docker compose up -d
```

### Backups
```bash
# Full backup (brief downtime — most reliable)
sudo bash scripts/backup.sh

# Hot backup (no downtime — dumps databases first)
sudo bash scripts/backup.sh --hot

# Custom output path
sudo bash scripts/backup.sh --hot /path/to/backup.tar.gz
```

### Restore (works on a fresh server too)
```bash
sudo bash scripts/restore.sh /path/to/backup.tar.gz
```

### Check status
```bash
docker compose ps
docker stats --no-stream
```

### Logs
```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f immich-server
```

---

## Resource Usage

Tested on an Intel N95 mini PC (16GB RAM):

| Service | RAM | CPU (idle) |
|---------|-----|-----------|
| Immich (server + ML) | ~1.5GB | <1% |
| Paperless (all components) | ~800MB | <1% |
| Jellyfin | ~300MB | <1% (higher during playback) |
| AdGuard Home | ~50MB | <1% |
| Vaultwarden | ~30MB | <1% |
| Uptime Kuma | ~80MB | <1% |
| Homepage | ~50MB | <1% |
| Nginx Proxy Manager | ~100MB | <1% |
| **Total** | **~3GB** | **<5%** |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Can't access services | Check `docker compose ps` — all should show "Up" |
| Port already in use | Change the port in docker-compose.yml |
| Immich ML slow | First run downloads models (~1.7GB). Be patient. |
| Paperless not OCR-ing | Check Tika and Gotenberg are running: `docker compose logs paperless-tika` |
| AdGuard DNS not working | Make sure port 53 isn't used by systemd-resolved: `sudo systemctl disable systemd-resolved` |
| Out of disk space | Check with `df -h`. Immich photos are the biggest consumer. |
| Forgot password | Check `credentials.txt` or `.env`, or reset via Docker exec |

### systemd-resolved conflict (common on Ubuntu)
AdGuard needs port 53, but Ubuntu's systemd-resolved uses it. Fix:
```bash
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
sudo rm /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

---

## What's NOT Included (and why)

- **Email server** — Self-hosted email is a nightmare. Use Proton Mail or Tuta instead.
- **Nextcloud** — Resource-heavy, often slow. Immich + Paperless cover photos + docs better.
- **VPN** — Too many variables (Wireguard vs OpenVPN, network config). Set up separately.
- **Plex** — Commercial, not open source. Jellyfin does the same thing, free.

---

## Credits

Built by a self-hosting enthusiast running 20+ containers daily. This is the exact stack I use for my family — battle-tested, not theoretical.

Questions? Open an issue or check r/selfhosted.

---

*Last updated: March 2026*
