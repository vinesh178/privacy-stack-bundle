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

After launch, open the instance's security group and add these inbound
**Custom TCP** rules, each with source **My IP**:

- Port 81 — setup administration
- Port 2283 — photos
- Port 8000 — documents
- Port 8096 — media
- Port 8080 — passwords
- Port 3001 — monitoring
- Port 3002 — dashboard

Do not use `0.0.0.0/0` for these test ports.

Launch the instance and copy its **Public IPv4 address**. On your computer, open
Terminal in the folder containing the downloaded key and run:

```bash
chmod 400 YOUR-KEY.pem
ssh -i YOUR-KEY.pem ubuntu@PUBLIC-IP
```

Replace `YOUR-KEY.pem` and `PUBLIC-IP` with the values from AWS.

## 2. Install

Paste this one command:

```bash
curl -fsSL https://raw.githubusercontent.com/vinesh178/privacy-stack-bundle/main/install.sh | sudo env PRESET=aws-credit bash
```

Installation can take 10–20 minutes. The installer configures:

- Immich
- Paperless-ngx
- Jellyfin
- Vaultwarden
- Uptime Kuma
- Homepage
- Nginx Proxy Manager

DNS and VPN are intentionally excluded from the first test because they require
additional network configuration.

## 3. Confirm it worked

When installation finishes, paste:

```bash
cd /opt/privacy-stack && sudo bash scripts/test.sh
cd /opt/privacy-stack && sudo ./bin/runctl status
```

Every enabled service should show a passing container check. If something
fails, collect:

```bash
cd /opt/privacy-stack
sudo docker compose ps
sudo docker compose logs --tail=100
```

Open the application URLs printed at the end of installation. They use the
instance's public IP and the ports allowed above.

## 4. Finish the test

Terminate the EC2 instance in the AWS console when testing is complete. Stopping
an instance preserves its disk and can continue to incur storage charges.
