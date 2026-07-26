# Release checklist

A release candidate is a go only when every item below passes.

- [ ] Repository-wide release policy passes: `bash tests/release-policy.sh`
- [ ] Bash syntax and ShellCheck pass
- [ ] `go test -race ./...` and `go vet ./...` pass
- [ ] Govulncheck reports no reachable vulnerabilities
- [ ] Full Compose configuration renders with every image pinned by digest
- [ ] Encrypted full and hot backup/restore round trips pass in isolated projects
- [ ] GitHub secret scan passes
- [ ] Fresh Ubuntu, Debian, or Amazon Linux install completes from `main`
- [ ] Tailscale login fallback is visible and succeeds
- [ ] Public SSH works before lockdown and fails after lockdown
- [ ] Tailscale SSH and all fixed application URLs work after lockdown
- [ ] AdGuard resolves DNS through the server's Tailscale address
- [ ] No secrets from `.env`, credentials, backups, or login URLs appear in logs

The automated items run in `.github/workflows/ci.yml`. The fresh-server items
remain a manual release gate because they validate cloud networking, systemd,
Docker firewall behavior, and browser-based Tailscale approval.
