# Deploying automatically on push

Everything else in this repo runs from your laptop. This makes GitHub do it
instead: push to `main`, and the site updates without you.

**Read the trade-off first.** It is not obviously the right choice.

---

## What it costs you

To deploy, GitHub needs an SSH key for your server. That key has `sudo`. So:

- **Anyone who can push to the repo can run commands on your server.** Not just
  deploy — anything, via a modified workflow file.
- **Anyone who can open a PR that runs workflows** is a possible route in, if
  you ever loosen the triggers.
- GitHub Actions has had secret-exfiltration incidents. Your key would be in
  scope for the next one.

For a solo project on a box that also serves nothing else, that may be fine. For
anything with a database you care about, laptop-driven deploys are genuinely the
safer design — the key never leaves your machine.

**Middle ground worth considering:** a second Unix user on the server that owns
only one app's directories and has no `sudo`. Give GitHub *that* key. More setup,
much smaller blast radius.

---

## What it gives you

- Deploys don't depend on your laptop being on, or on you remembering
- Every deploy is logged, attributed and repeatable
- A teammate can ship without your SSH key
- It runs the same steps as `./update.sh`: fetch, install, build, atomic release,
  restart, prune

---

## Setup

### 1. Copy the workflow into your app's repo

Not this one — the workflow belongs beside the code it deploys.

```bash
cp .github/workflows/deploy.yml.example ../your-app/.github/workflows/deploy.yml
```

### 2. Add the secrets

In your app's repo → **Settings → Secrets and variables → Actions → Secrets**:

| Secret | Value |
|---|---|
| `VPS_HOST` | your server IP |
| `VPS_USER` | `ubuntu` |
| `VPS_SSH_KEY` | the **entire** `.pem`, including `-----BEGIN` and `-----END` |

`VPS_SSH_KEY` catches people out: paste the whole file, newlines included, not
a single line.

### 3. Add the variables

Same page, **Variables** tab:

| Variable | Example | Notes |
|---|---|---|
| `APP_DIR` | `/home/ubuntu/apps/news` | the checkout on the server |
| `WEB_ROOT` | `/var/www/news` | releases + `current` symlink |
| `PM2_NAME` | `news` | **omit entirely for a static site** |
| `BUILD_CMD` | `npm run build` | omit if there is no build |

Get the first two from your existing config:

```bash
grep -E "^(APP_DIR|WEB_ROOT|APP_NAME)=" next/next-deploy.main.conf
```

`PM2_NAME` is what decides which path the workflow takes. Set it and the whole
app tree is released and pm2 restarted. Leave it unset and only `dist/`, `build/`
or `out/` is published — the static-site path.

### 4. Provision once from your laptop first

**The workflow updates an existing deployment. It does not create one.** nginx
config, certificates, the pm2 process and the directory layout all come from
`setup`:

```bash
cd next && ./next-deploy.sh setup main
```

Once that has worked, push to `main` and Actions takes over.

---

## What it does not do

Deliberately, so it stays predictable:

- **No provisioning.** No nginx config, no certbot, no package installs.
- **No env upload.** The `.env` on the server stays as `./edit-env.sh` left it —
  the workflow explicitly preserves it across `git reset --hard`, which would
  otherwise revert a tracked `.env`. Keep app secrets out of GitHub.
- **No rollback.** Use the laptop tooling:
  ```bash
  ./next-deploy.sh rollback main
  ```

So both paths coexist. Actions handles the routine push-to-deploy; the scripts
remain for anything that needs judgement.

---

## Guards it keeps

The workflow is not a stripped-down version. It keeps the parts that were added
because something actually broke:

- **Disk check before building** — refuses under 300 MB free rather than filling
  the volume, which has taken this server down before
- **`.env` preserved across `git reset --hard`** — a repo that tracks `.env` will
  otherwise have your uploaded one silently reverted mid-deploy
- **Atomic symlink swap** — build a new symlink, `mv -Tf` over the old one
- **Build output verified** before anything is published
- **Health check** on the port after a pm2 restart
- **Prune to 3 releases**, never the live one
- **`concurrency`** so two pushes cannot deploy over each other
- **Host key pinned** with `ssh-keyscan` rather than
  `StrictHostKeyChecking=no` — a swapped server fails loudly

---

## Checking it worked

Actions tab → the run → the **Deploy** step. You want:

```
--- a1b2c3d Add the Movies tab
--- live: 20260801-140533-a1b2c3d
responded OK
```

Then confirm for yourself:

```bash
./next-deploy.sh status main
```

```bash
curl -I https://your-domain
```

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Permission denied (publickey)` | `VPS_SSH_KEY` is truncated — paste the whole file |
| `Host key verification failed` | server rebuilt or IP reused; re-run the workflow |
| `ERROR: only NNNMB free` | the disk guard did its job — free space or grow the volume |
| `no build output` | `BUILD_CMD` is unset, or it writes somewhere other than `dist`/`build`/`out` |
| `sudo: a password is required` | the SSH user lacks passwordless sudo |
| Deploys but the site is unchanged | wrong `WEB_ROOT`, or `PM2_NAME` set on a static site |
| `pm2: command not found` | never provisioned from the laptop — do step 4 |
