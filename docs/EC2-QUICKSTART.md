# EC2 quick start

This path is designed for a first-time, non-technical tester with AWS credits.

## 1. Create the server

In the AWS EC2 console, choose **Launch instance** and use:

- Name: `privacy-stack-test`
- Image: Ubuntu Server 24.04 LTS
- Architecture: 64-bit x86
- Instance type: `m7i-flex.large` when Free Tier eligible, otherwise `t3.large`
- Storage: 60 GB gp3
- Key pair: create or select an RSA `.pem` key
- Security group: allow SSH from **My IP** only

Do not add public application ports. Tailscale provides application access.

Launch the instance and copy its **Public IPv4 address**. On your computer, open
Terminal in the folder containing the downloaded key and run:

```bash
chmod 400 YOUR-KEY.pem
ssh -i YOUR-KEY.pem ubuntu@PUBLIC-IP
```

Replace `YOUR-KEY.pem` and `PUBLIC-IP` with the values from AWS.

## 2. Install

Clone the repository and run the fixed fresh-server setup:

```bash
git clone https://github.com/vinesh178/privacy-stack-bundle.git
cd privacy-stack-bundle
sudo bash setup-server.sh
```

Run this in the interactive SSH session. The Tailscale login and final
`LOCKDOWN` confirmation require the terminal so the installer cannot silently
lock you out.

Installation can take 10–20 minutes. The installer configures:

- Immich
- Paperless-ngx
- Jellyfin
- AdGuard Home
- Vaultwarden
- Uptime Kuma
- Homepage
- Nginx Proxy Manager
- Tailscale

The setup displays a Tailscale login link. After login, it pauses for the
AdGuard wizard, then asks you to verify SSH through the displayed Tailscale IP.
Only after both checks does it disable public SSH and application ports.

## 3. Confirm it worked

When installation finishes, paste:

```bash
sudo bash scripts/test.sh
sudo docker compose ps
```

Every enabled service should show a passing container check. If something
fails, collect:

```bash
sudo docker compose ps
sudo docker compose logs --tail=100
```

Open the application URLs using the Tailscale IP printed at the end of setup.

### Use AdGuard from any Wi-Fi

1. Open `http://TAILSCALE-IP:3000`.
2. Complete the AdGuard wizard. Keep the admin interface on port `3000`; run
   DNS on port `53`.
3. In the Tailscale admin console, open **DNS**.
4. Add the VPS `100.x.y.z` Tailscale IP as a **global nameserver**.
5. Enable **Override DNS servers**.

Every connected Tailscale device will then send DNS through the encrypted
tailnet to AdGuard, including on hotel or airport Wi-Fi. This filters DNS only;
it does not route all browsing traffic through the VPS.

## 4. Finish the test

Terminate the EC2 instance in the AWS console when testing is complete. Stopping
an instance preserves its disk and can continue to incur storage charges.
