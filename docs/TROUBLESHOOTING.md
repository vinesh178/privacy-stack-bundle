# Troubleshooting

Run commands from the repository directory. Public bootstrap installations use:

```bash
cd /opt/privacy-stack
```

For a single read-only summary of all Tailscale addresses, peers, SSH and
application URLs, Nginx targets, DNS details, and Kuma monitor URLs, run:

```bash
sudo bash scripts/network-info.sh
```

Keep the original public SSH session open until Tailscale SSH works from a
second terminal.

## Applications do not open on the public IP

This is intentional. The recommended EC2 security group exposes only temporary
SSH, and the final lockdown blocks all new public ingress. Connect the client
device to Tailscale and use the server's `100.x.y.z` address:

```bash
sudo docker exec tailscale tailscale ip -4
```

For example, Uptime Kuma is `http://100.x.y.z:3001`.

## Tailscale reports `NeedsLogin` or prints `EOF`

Request a device login:

```bash
sudo docker exec -it tailscale tailscale up --accept-dns=false
```

Open the displayed URL and approve the `privacy-stack` device. The browser
account being logged in is not enough; the new device must also be approved.
Verify the server received an address:

```bash
sudo docker exec tailscale tailscale ip -4
```

If the interrupted installer returned to the shell after approval, continue
without replacing `.env` or application data:

```bash
sudo bash /opt/privacy-stack/setup-server.sh --resume
```

If the installer is still stuck at `Connecting this server to Tailscale...` but
the IP command already prints `100.x.y.z`, press **Ctrl-C** once and use the
resume command above. Do not interrupt while firewall lockdown is running.

## SSH after `LOCKDOWN`

`LOCKDOWN` blocks new SSH connections through the public interface, including
public-IP EC2 Instance Connect/browser SSH. Connect through Tailscale:

```bash
ssh -i /path/to/private-key.pem ubuntu@100.x.y.z
```

Separately configured out-of-band access, such as AWS Systems Manager Session
Manager, may remain available because it does not depend on new inbound public
SSH. Do not assume it is configured; verify Tailscale SSH before lockdown.

The client needs the private key matching a public key in
`~/.ssh/authorized_keys`; a `.pub` file alone cannot authenticate. If necessary,
add a new public key using the still-open original SSH session before lockdown.
The installer prints both SSH command forms again on its final success screen.

## Git reports dubious ownership

The public bootstrap clones `/opt/privacy-stack` as root. Update it with:

```bash
cd /opt/privacy-stack
sudo git pull --ff-only origin main
```

Do not change repository ownership or add a global `safe.directory` exception.

## Uptime Kuma is empty

Kuma does not provision monitors before its first-run admin account exists.
Open `http://TAILSCALE-IP:3001`, create the account, then add HTTP(s) monitors:

| Name | URL |
|---|---|
| Paperless | `http://paperless:8000` |
| Jellyfin | `http://jellyfin:8096` |
| Vaultwarden | `http://vaultwarden:80` |
| Homepage | `http://homepage:3000` |
| Nginx Proxy Manager | `http://nginx-proxy-manager:81` |
| AdGuard | `http://adguard:80` |

AdGuard should be added only after its first-run wizard is complete. Kuma checks
again automatically at the configured heartbeat interval. Its current UI uses
**Pause** and **Resume**; there is no **Retry Now** action.

Test every URL from inside the Kuma container:

```bash
sudo docker exec uptime_kuma node -e "
const services = {
  Paperless: 'http://paperless:8000',
  Jellyfin: 'http://jellyfin:8096',
  Vaultwarden: 'http://vaultwarden:80',
  Homepage: 'http://homepage:3000',
  'Proxy Manager': 'http://nginx-proxy-manager:81',
  AdGuard: 'http://adguard:80'
};
for (const [name, url] of Object.entries(services)) {
  fetch(url)
    .then(response => console.log(name, response.status))
    .catch(error => console.log(name, error.message));
}
"
```

## Kuma reports `ENOTFOUND`

The service name did not resolve through Docker DNS. Confirm Kuma and the target
share the `privacy-stack` network:

```bash
sudo docker inspect uptime_kuma \
  --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}} {{end}}'
sudo docker inspect paperless \
  --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}} {{end}}'
sudo docker exec uptime_kuma getent hosts paperless
```

Both inspections should include `privacy-stack`, and `getent` should print the
Paperless container IP. Then test HTTP separately:

```bash
sudo docker exec uptime_kuma node -e \
"fetch('http://paperless:8000').then(r => console.log('HTTP', r.status)).catch(console.error)"
```

## Kuma reports `ECONNREFUSED`

DNS worked, but the target application was not listening. Check its restart
count and logs:

```bash
sudo docker inspect paperless \
  --format 'status={{.State.Status}} restarts={{.RestartCount}} exit={{.State.ExitCode}}'
sudo docker logs --tail=100 paperless
```

An older installation may show database authentication failures for user
`paperless`. Current `main` explicitly aligns Paperless with the PostgreSQL
`postgres` user. Apply it without deleting the database:

```bash
cd /opt/privacy-stack
sudo git pull --ff-only origin main
sudo docker compose up -d --no-deps --force-recreate paperless
```

Wait for the next Kuma heartbeat, or use **Pause** and **Resume** on the monitor.

## Collect a general health report

```bash
cd /opt/privacy-stack
sudo bash scripts/test.sh
sudo docker compose ps
sudo docker compose logs --tail=100
```

Generated credentials are stored at `/opt/privacy-stack/credentials.txt`:

```bash
sudo cat /opt/privacy-stack/credentials.txt
```

The underlying generated secrets are stored in `/opt/privacy-stack/.env`. Both
files are excluded from Git; do not paste their contents into bug reports.
