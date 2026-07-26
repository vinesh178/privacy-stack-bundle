# Privacy Stack Bundle

An opinionated self-hosted privacy stack for a fresh Linux server. The setup
installs one fixed service set and removes public ingress after Tailscale access
has been verified.

## Included services

| Service | Purpose | Tailscale port |
|---|---|---:|
| Immich | Photos | 2283 |
| Paperless-ngx | Documents and OCR | 8000 |
| Jellyfin | Media | 8096 |
| AdGuard Home | Ad-blocking DNS | 53, 3000 |
| Vaultwarden | Password manager | 8080 |
| Uptime Kuma | Monitoring | 3001 |
| Homepage | Dashboard | 3002 |
| Nginx Proxy Manager | Reverse proxy | 81 |
| Tailscale | Private network access | VPN |

Databases, Redis, Tika, and other service dependencies are isolated on internal
Docker networks and are not published as product endpoints.

## Requirements

- Fresh Ubuntu, Debian, or Amazon Linux server with systemd
- At least 8 GB RAM
- At least 40 GB free disk space; 60 GB is recommended
- A free Tailscale account
- Temporary SSH access from your IP during setup

## Install

```bash
git clone https://github.com/vinesh178/privacy-stack-bundle.git
cd privacy-stack-bundle
sudo bash setup-server.sh
```

The installer:

1. Validates the operating system, memory, disk, and fresh-install state.
2. Installs Docker.
3. Generates unique passwords and writes them to `credentials.txt` with mode
   `600`.
4. Starts the fixed Docker Compose stack.
5. Runs the service health gate.
6. Opens the Tailscale login flow.
7. Guides you through AdGuard's first-run wizard over Tailscale.
8. Asks you to verify VPN-based SSH from a second terminal.
9. Blocks public SSH and Docker ingress and persists the lockdown with systemd.

The public bootstrap performs the same setup:

```bash
curl -fsSL https://raw.githubusercontent.com/vinesh178/privacy-stack-bundle/main/install.sh | sudo bash
```

Run the installer from an interactive SSH terminal. Tailscale authentication
and the final `LOCKDOWN` confirmation use that terminal deliberately to prevent
accidental remote lockout.

See [EC2 quick start](docs/EC2-QUICKSTART.md) for AWS instructions.

### If Tailscale remains at `NeedsLogin`

The login page can report success just after the container command disconnects
with `EOF`. The installer now waits up to five minutes for that browser approval.
If the installer has already exited, verify the server from its SSH session:

```bash
sudo docker exec tailscale tailscale ip -4
```

If it still reports `NeedsLogin`, request a fresh device login:

```bash
sudo docker exec -it tailscale tailscale up --accept-dns=false
```

Open the displayed URL, approve the `privacy-stack` device, and run the IP check
again. A successful connection prints a `100.x.y.z` address. Continue the
interrupted installer without overwriting its configuration:

```bash
sudo bash /opt/privacy-stack/setup-server.sh --resume
```

Keep the original public SSH session open until VPN SSH and the final lockdown
have both been confirmed. If you installed with `git clone` instead of the
public bootstrap, run `sudo bash setup-server.sh --resume` from the cloned
repository directory.

## AdGuard through Tailscale

After installation:

1. Open `http://TAILSCALE-IP:3000`.
2. Complete the AdGuard wizard, keeping its admin interface on port `3000` and
   DNS on port `53`.
3. In the Tailscale admin console, add the VPS Tailscale IP as a global
   nameserver.
4. Enable **Override DNS servers**.

Connected devices then use AdGuard over the encrypted tailnet on home, hotel,
airport, or mobile networks. This filters DNS traffic; it does not make the VPS
an exit node.

Application URLs, generated credentials, and Homepage links are rewritten to
the stable Tailscale IP before public ingress is disabled.

The VPS itself is configured with Tailscale DNS acceptance disabled so it does
not feed its own resolver back into AdGuard when the tailnet-wide DNS override
is enabled.

## Operations

```bash
# Health
sudo bash scripts/test.sh

# Status
sudo docker compose ps

# Logs
sudo docker compose logs -f SERVICE

# Update containers
sudo docker compose pull
sudo docker compose up -d

# Full backup (brief downtime)
sudo bash scripts/backup.sh

# Hot backup
sudo bash scripts/backup.sh --hot

# Restore
sudo bash scripts/restore.sh /path/to/backup.tar.gz
```

Generated configuration, credentials, and data are ignored by Git. Backups may
contain secrets and application data; store them securely.

## Experimental next phase

The repository also retains the experimental Go-based `runctl` catalog,
planning, receipt, and status implementation. It is intentionally not the
current setup path. Work on that MVP resumes after the fixed
`setup-server.sh` flow passes fresh-server and EC2 validation.

## Network model

- `proxy` (`privacy-stack`) connects user-facing services.
- `immich` contains Immich and its dependencies.
- `paperless` contains Paperless-ngx and its dependencies.
- Tailscale uses the host network.
- `scripts/lockdown-vpn.sh` allows Tailscale ingress, removes public SSH, and
  blocks Docker-published ports arriving on the public interface.

## License

Copyright © 2026 Vinesh Kumar.

Licensed under the [GNU Affero General Public License v3.0](LICENSE). Commercial
use and paid hosting are permitted under the license. A future managed service
may include separately priced hosting, operations, support, backups, and
monitoring.
