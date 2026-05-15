# Deploying to Oracle Cloud (Always Free)

This guide runs the orchestrator 24/7 at zero recurring cost on an Oracle Cloud Infrastructure (OCI) Always Free Ampere ARM VM, exposed via Cloudflare's Quick Tunnel.

## What you get

- One Ubuntu 22.04 ARM VM (Always Free shape `VM.Standard.A1.Flex`)
- Docker Compose stack: `orchestrator` + `cloudflared`
- HTTP Basic Auth in front of the UI
- A public HTTPS URL like `https://<random>.trycloudflare.com`
- Auto-deploy on GitHub release

## Constraints to know about

- **Single replica.** `Storage::JsonFileStorage` uses in-process mutexes; running multiple instances would corrupt state.
- **JSON state on host disk.** Persisted at `/opt/orchestrator/data` on the VM's boot volume. Not backed up by default.
- **Ephemeral public URL.** Cloudflare Quick Tunnels generate a new URL each time `cloudflared` restarts (VM reboot, container restart, redeploy). Use `deploy/show-url.sh` to fetch the current URL. If this becomes annoying, upgrade to a named Cloudflare Tunnel (requires a domain).
- **Quick Tunnels are best-effort.** Cloudflare documents them as a testing tool. Fine for personal use.
- **Oracle may reclaim idle Always Free VMs.** The orchestrator's polling loop generates enough activity to count as in-use.

## One-time VM setup

### 1. Provision the VM

In the OCI console:

- Shape: `VM.Standard.A1.Flex`
- 2 OCPU / 12 GB RAM (room to grow within the free 4/24 ceiling)
- OS image: **Canonical Ubuntu 22.04** (ARM)
- Add your SSH public key
- Note the assigned public IP

VCN ingress: only TCP **22** needs to be open. Quick Tunnel is outbound-only, so no 80/443.
Host firewall: no `iptables` changes needed — the orchestrator port is never bound to the host.

### 2. Install Docker

```bash
ssh ubuntu@<vm-ip>
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu
exit          # log out so the group change applies
ssh ubuntu@<vm-ip>
docker version
```

### 3. Clone the repo and create the data dir

```bash
sudo mkdir -p /opt/orchestrator/data
sudo chown ubuntu:ubuntu /opt/orchestrator/data
sudo git clone https://github.com/alysonbasilio/autonomous-product-team.git /opt/orchestrator/repo
cp /opt/orchestrator/repo/deploy/.env.example /opt/orchestrator/repo/deploy/.env
$EDITOR /opt/orchestrator/repo/deploy/.env   # fill in real values
```

### 4. Install + enable the systemd unit

```bash
sudo cp /opt/orchestrator/repo/deploy/orchestrator.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now orchestrator
```

### 5. Allow passwordless restart for the deploy user

The GitHub Action only needs sudo to restart the service:

```bash
echo 'ubuntu ALL=(root) NOPASSWD: /bin/systemctl restart orchestrator' \
  | sudo tee /etc/sudoers.d/orchestrator-deploy
sudo chmod 440 /etc/sudoers.d/orchestrator-deploy
```

### 6. Add a deploy SSH key

On a trusted machine (not the VM):

```bash
ssh-keygen -t ed25519 -f orchestrator-deploy -N ""
```

Append `orchestrator-deploy.pub` to `/home/ubuntu/.ssh/authorized_keys` on the VM. Keep the private half (`orchestrator-deploy`) for the GitHub secret in the next section.

Capture the VM's host key for `known_hosts` pinning:

```bash
ssh-keyscan <vm-ip>
```

### 7. Fetch the tunnel URL

```bash
/opt/orchestrator/repo/deploy/show-url.sh
```

Open the printed `https://<random>.trycloudflare.com` URL in a browser. You'll be prompted for the Basic Auth credentials from `deploy/.env`.

## GitHub Actions: deploy on release

Add these secrets to the repository (`Settings → Secrets and variables → Actions`):

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | Public IP (or DNS name) of the OCI VM |
| `DEPLOY_USER` | `ubuntu` |
| `DEPLOY_SSH_KEY` | Contents of the `orchestrator-deploy` private key generated above |
| `DEPLOY_KNOWN_HOSTS` | Output of `ssh-keyscan <vm-ip>` |

The workflow at `.github/workflows/deploy.yml` triggers on every published release and SSHes to the VM, checks out the release tag, and restarts the systemd unit.

### Cutting a release

```bash
gh release create vX.Y.Z --notes "What changed"
```

After the workflow finishes, SSH in and grab the new URL:

```bash
ssh ubuntu@<vm-ip> /opt/orchestrator/repo/deploy/show-url.sh
```

### Manual deploy (fallback)

You can also trigger the workflow manually from the Actions tab — pick a tag or branch via `workflow_dispatch`. Or, if Actions are unavailable:

```bash
ssh ubuntu@<vm-ip>
cd /opt/orchestrator/repo
git fetch --tags
git checkout <tag-or-branch>
sudo systemctl restart orchestrator
```

## Required env vars (deploy/.env)

| Var | Purpose |
|---|---|
| `SYNTHUP_TENANT` | Synthup tenant. Hides the UI field. |
| `SYNTHUP_API_KEY` | Synthup API key. Hides the UI field. |
| `ORCHESTRATOR_USERNAME` | Basic Auth username |
| `ORCHESTRATOR_PASSWORD` | Basic Auth password. When unset, auth is skipped — never leave blank in production. |

The orchestrator container also reads `PORT`, `ORCHESTRATOR_BIND`, and `ORCHESTRATOR_DATA_DIR`, all set in `docker-compose.yml`.

## Backups (optional)

`/opt/orchestrator/data` is on the VM boot volume. If losing project state would hurt, set up a periodic `rsync` to OCI Object Storage (also Always Free, 20 GB).
