# Setup — from nothing to a live HTTPS Node.js site

Do this **once per project**. Afterwards you only need [UPDATE.md](UPDATE.md).

---

## Before you start

| Need | Detail |
|---|---|
| Git Bash | This is a bash script. It will **not** run in PowerShell or CMD. |
| `.pem` key | The SSH key for the server, e.g. `testing.pem` in the parent folder. |
| Server | Passwordless `sudo` for the SSH user. |
| Repo URL | `https://github.com/you/repo.git` |
| GitHub token | Only for a private repo. A PAT with **Contents: Read**. |
| A domain | One per environment, pointed at the server. |
| A start command | `npm start`, `node server.js`, `node dist/main.js` |

```bash
cd /c/Users/suraj/Downloads/vps/next
```

### Your start command

```json
// package.json
"scripts": {
  "start": "node server.js"
}
```

Whatever you give as the start command is what pm2 runs, from the release
directory, with `PORT` and your uploaded `.env` already in scope. It must stay
in the foreground — a command that daemonises itself will make pm2 think the
process died.

### Budget the resources

A Node.js environment is a **running process**, not a folder of files:

| Per environment | Roughly |
|---|---|
| RAM (idle SSR process) | 150–250 MB |
| Disk (checkout + `node_modules` + 3 releases) | 600 MB – 1 GB |

Check what you have before committing to two environments:

```bash
./node-deploy.sh status        # once configured
# or straight from the server:
free -m ; df -h /
```

On a 1 GB / 8 GB box, one Node.js environment alongside an existing app is
comfortable. Two is not, without resizing.

---

## Step 1 — DNS

Point every domain at the server. Same IP for all of them:

```
example.com       A   <server ip>
dev.example.com   A   <server ip>
```

- **A bare hostname** — not `http://…`, no trailing `/`. The script strips these
  anyway, and rejects invalid ones.
- **No underscores.** `dev_site.example.com` is not a valid hostname.
- **Don't reuse a domain** already serving another site on this box.

DNS not ready? Setup still completes over HTTP and skips the certificate; run
`./node-deploy.sh ssl <env>` once it propagates.

---

## Step 2 — Run setup

```bash
./node-deploy.sh setup
```

Note the `./` — without it bash searches `$PATH`, which doesn't include the
current directory.

### How many environments?

```
    1   production only          main -> your live domain
    2   + develop                develop -> its own domain
    3   + staging                staging -> its own domain
    4+  qa, uat, demo, preview, then env5, env6, ...
```

Environment 1 asks everything. Environments 2+ inherit the server, key, repo and
token, and only ask what differs — **name, branch, port, domain, env file**.
Ports auto-increment (3000, 3001, …) and are checked for clashes.

### Answering the questions

Every prompt shows a default in `[brackets]`. **Enter** accepts it.
**`-` clears a field** back to empty.

| Prompt | Notes |
|---|---|
| Path to `.pem` key | auto-detected from this folder or the parent |
| Repo URL | HTTPS form, ending `.git` |
| Private repo? | `y` → username + token; typing is hidden |
| Branch | **verified against the repo immediately** |
| Site name | drives the pm2 process name, `/var/www/<name>` and the nginx block |
| Install command | leave as `npm ci` — **never** `--omit=dev`, the build needs devDependencies |
| **Port** | must be unique per environment; checked against your other configs |
| Max memory | pm2 restarts the process above this (default `500M`) |
| Domain | bare hostname, or `-` for IP only |
| Let's Encrypt email | needed for HTTPS |

### The branch check

```
==> Verifying repo access and branch 'develop'
  ✓ Repo reachable — 2 branch(es) found
  ✓ Branch 'develop' exists
```

Catches a wrong repo URL, an expired token, and a typo'd branch — before
anything touches the server.

---

## Step 3 — Environment variables

One file per environment, next to the scripts:

```
.env.production    DATABASE_URL=...   APP_SITE_URL=https://example.com
.env.develop       DATABASE_URL=...   APP_SITE_URL=https://dev.example.com
```

Naming is `.env.<environment name>` — auto-detected, nothing to configure.

**Node.js splits variables in two**, and the difference matters:

| | Where it goes | To change it |
|---|---|---|
| `environment variables` | compiled into the **browser bundle** at build time | rebuild |
| everything else | read by the **server** at runtime | restart (seconds) |

So unlike a React SPA, this file **can** hold real secrets — as long as they
don't carry the `APP_` prefix. `edit-env.sh` warns if a `APP_`
name looks secret.

> If your repo **commits** its `.env`, the deploy handles it: the uploaded file
> is backed up before `git reset --hard` and restored after, since git would
> otherwise revert it to the committed version.

---

## Step 4 — Go live

```bash
./node-deploy.sh setup all        # every environment
./node-deploy.sh setup develop    # or one at a time
```

What happens, in order:

```
 1. SSH + passwordless sudo check    ← stops here if either fails
 2. Check the stack                  ← node, pm2, nginx, certbot; installs only
                                        what's missing, warns on port clashes
 3. Store git credentials
 4. Upload .env.<environment>
 5. Clone → npm ci → next build      ← ensures 3 GB swap first; a Next build
                                        is OOM-killed on a small box without it
 6. Copy the app into a release     ← everything except .git
 7. Flip the symlink, pm2 restart
 8. Health check on 127.0.0.1:PORT   ← waits up to 40s
 9. nginx server block + reload
10. Certbot + HTTP→HTTPS redirect    ← skipped if DNS isn't ready
```

Step 2 is a fast no-op on a server that already hosts something:

```
[present] curl git ca-certificates gnupg build-essential ufw
[present] node v22.23.1 / npm 10.9.8
[present] pm2 6.x
[present] nginx version: nginx/1.28.3 (Ubuntu)
[present] certbot 4.0.0
```

---

## Step 5 — Verify

```bash
./node-deploy.sh status develop
```

```
=== pm2 ===          status: online, restarts: 0, memory: 180mb
=== live release === /var/www/site/current -> releases/20260725-...-abc1234
=== port 3001 ===    local HTTP 200 in 0.09s
=== nginx ===        active
```

Then in a browser: `https://<domain>` loads, `http://` redirects, and an API
route (`/api/...`) responds.

---

## When something goes wrong

| Symptom | Cause |
|---|---|
| `command not found` | Missing `./`, or you're in PowerShell not Git Bash |
| `$'\r': command not found` | CRLF line endings — `dos2unix node-deploy.sh` |
| `no node_modules in the release` | the install failed — read the deploy output |
| Build "Killed" with no error | Out of RAM. The script adds 3 GB swap; check disk too |
| `no response on :PORT` | `./node-deploy.sh logs <env>` — the app crashed on boot |
| Port already listening | Another process owns it; pick a different port via `config` |
| 502 from nginx | The Node process is down — check `pm2 status` |
| certbot fails | DNS isn't pointing here yet. Fix the A record, run `ssl <env>` |

Full command list: `./node-deploy.sh help`
