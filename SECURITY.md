# Security policy

## Supported version

Security fixes are applied to the latest commit on `main`. Deployments should
update from `main` and recreate containers from the release-pinned images.

## Reporting a vulnerability

Please do not open a public issue for an undisclosed vulnerability. Use
GitHub's **Report a vulnerability** button in this repository's Security tab to
send a private report.

Include the affected commit, deployment profile, Linux distribution, steps to
reproduce, and likely impact. Do not include real `.env`, `credentials.txt`,
backup archives, access keys, or Tailscale login URLs.

This project is maintained on a best-effort basis. Reports will be
acknowledged when reviewed; no fixed response or remediation timeline is
guaranteed.
