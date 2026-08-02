# Privacy Stack Bundle

An opinionated self-hosted privacy stack for a fresh Linux server. The setup
installs one fixed service set and removes public ingress after Tailscale access
has been verified.

## Included services

| Service | Purpose | Tailscale port |
|---|---|---:|
| Paperless-ngx | Documents and OCR | 8000 |
| Jellyfin | Media | 8096 |
| AdGuard Home | Ad-blocking DNS | 53, 3003 |
| Uptime Kuma | Monitoring | 3001 |
| Homepage | Dashboard | 3002 |
| Tailscale | Private network access | VPN |

Databases, Redis, Tika, and other service dependencies are isolated on internal
Docker networks and are not published as product endpoints.

## Requirements

- Fresh Ubuntu, Debian, or Amazon Linux server with systemd
- At least 8 GB RAM
- At least 20 GB free disk space; a 40 GB disk is recommended
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

The public bootstrap performs the same setup (downloads first, then runs):

```bash
curl -fsSL https://raw.githubusercontent.com/vinesh178/privacy-stack-bundle/main/install.sh -o /tmp/privacy-stack-install.sh && bash /tmp/privacy-stack-install.sh
```

The script self-elevates to root — no need to prepend `sudo`. It works whether
you are already root (fresh VPS), have `sudo` available (Ubuntu default user),
or only have `su`.

Run the installer from an interactive SSH terminal. Tailscale authentication
and the final `LOCKDOWN` confirmation use that terminal deliberately to prevent
accidental remote lockout.

See [EC2 quick start](docs/EC2-QUICKSTART.md) for AWS instructions and
[Troubleshooting](docs/TROUBLESHOOTING.md) for the recovery commands validated
on a fresh EC2 installation.

Release maintainers should also run the post-reboot gate in
[the release checklist](docs/RELEASE-CHECKLIST.md) before publishing a version.

### Show every network address

After setup, print the server's Tailscale addresses, tailnet devices, SSH
command, application URLs, optional reverse-proxy targets, AdGuard DNS address,
and Uptime Kuma monitor URLs in one place:

```bash
cd /opt/privacy-stack
sudo bash scripts/network-info.sh
```

### If the Tailscale login URL does not appear

Keep the installer open. In a second SSH session, run:

```bash
sudo docker exec tailscale tailscale up --accept-dns=false
```

Open the displayed URL and approve the `privacy-stack` device. The original
installer then polls for the approved VPN address for up to five minutes.

### If Tailscale remains at `NeedsLogin`

The login page can report success just after the container command disconnects
with `EOF`. The installer then polls for up to five minutes for browser approval.
If the installer has already exited, verify the server from its SSH session:

```bash
sudo docker exec tailscale tailscale ip -4
```

If it still reports `NeedsLogin`, request a fresh device login:

```bash
sudo docker exec tailscale tailscale up --accept-dns=false
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

1. Open the first-run wizard at `http://TAILSCALE-IP:3000`.
2. Complete the wizard, keeping its admin interface on port `80` and DNS on
   port `53`.
3. After setup, use `http://TAILSCALE-IP:3003` for the permanent dashboard.
4. In the Tailscale admin console, add the VPS Tailscale IP as a global
   nameserver.
5. Enable **Override DNS servers**.

Connected devices then use AdGuard over the encrypted tailnet on home, hotel,
airport, or mobile networks. This filters DNS traffic; it does not make the VPS
an exit node.

Application URLs, generated credentials, and Homepage links are rewritten to
the stable Tailscale IP before public ingress is disabled.

The VPS itself is configured with Tailscale DNS acceptance disabled so it does
not feed its own resolver back into AdGuard when the tailnet-wide DNS override
is enabled.

## Uptime Kuma first run

Uptime Kuma starts without monitors because its admin account must be created
on first use:

1. Open `http://TAILSCALE-IP:3001`.
2. Create the Uptime Kuma admin account.
3. Select **Add New Monitor**, choose **HTTP(s)**, and add:

| Name | Internal URL |
|---|---|
| Paperless | `http://paperless:8000` |
| Jellyfin | `http://jellyfin:8096` |
| Homepage | `http://homepage:3000` |
| AdGuard | `http://adguard:80` |

These internal Docker addresses keep monitoring independent of the server's
public and Tailscale addresses. Add AdGuard only after its first-run wizard is
complete. Kuma checks again at the configured heartbeat interval; its current
UI uses **Pause** and **Resume**, not a **Retry Now** action.

See [Troubleshooting](docs/TROUBLESHOOTING.md#uptime-kuma-is-empty) for a single
command that tests every monitor URL from inside the Kuma container.

## Operations

```bash
# Health
sudo bash scripts/test.sh

# Status
sudo docker compose ps

# Logs
sudo docker compose logs -f SERVICE

# Update to the release-pinned container versions
sudo git pull --ff-only origin main
sudo docker compose pull
sudo docker compose up -d

# Full backup (brief downtime)
sudo bash scripts/backup.sh

# Hot backup
sudo bash scripts/backup.sh --hot

# Restore
sudo bash scripts/restore.sh /path/to/backup.tar.gz.age
```

Generated configuration, credentials, and data are ignored by Git. Backups may
contain secrets and application data; store them securely.

Backups use age's authenticated encryption by default and prompt twice for a
passphrase. Restore
prompts for the same passphrase and requires the adjacent `.sha256` checksum
file. Store the passphrase separately from both files. For automation, provide
a root-readable file with
`--passphrase-file=/secure/path/backup-passphrase`; the passphrase is never
written into the archive or command output. `--unencrypted` exists only for
explicit local testing.

Nginx Proxy Manager (`proxy`) and Vaultwarden (`passwords`) remain optional
Compose profiles for future domain-and-HTTPS testing. They are deliberately
excluded from the fixed MVP: Vaultwarden's browser vault requires a secure
HTTPS context, and the current release does not promise public-domain
certificate automation.

## Release security

- Application ports are blocked on the public interface before containers
  start; public SSH remains available only for onboarding.
- Final lockdown occurs only after the user verifies SSH through Tailscale.
- Generated `.env`, credentials, backup archives, and checksums use mode `600`.
- Container images and bootstrap downloads are pinned and checksum-verified.
- Homepage does not receive access to the Docker daemon socket.
- Restore validates its checksum, archive paths, manifest version, project
  name, profiles, and data directory before replacing data.

## Experimental next phase

The repository also retains the experimental Go-based `runctl` catalog,
planning, receipt, and status implementation. It is intentionally not the
current setup path. Work on that MVP resumes after the fixed
`setup-server.sh` flow passes fresh-server and EC2 validation.

## Network model

- `proxy` (`privacy-stack`) connects user-facing services.
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
