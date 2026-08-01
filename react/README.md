# React (Vite/CRA) → VPS deployment

CI/CD for a React single-page app on your own server. Push to GitHub, run one
command, the server builds and publishes it.

Everything runs **from your laptop in Git Bash** over SSH. Nothing is installed
on your machine, and no CI service is involved.

```bash
cd /c/Users/suraj/Downloads/vps/react
```

---

## Contents

| Doc | Script | Covers |
|---|---|---|
| [SETUP.md](SETUP.md) | `react-develop.sh` | first-time setup, one or many environments |
| [UPDATE.md](UPDATE.md) | `update.sh` | the daily loop after you push |
| [EDIT-ENV.md](EDIT-ENV.md) | `edit-env.sh` | change variables and apply them |
| [REMOVE-ENV.md](REMOVE-ENV.md) | `remove-env.sh` | delete an environment |

---

## What you get

- **One command per deploy.** `git push`, then `./update.sh`.
- **Multiple environments** — production, develop, staging… each on its own
  branch, domain, directory and release history.
- **Atomic releases.** Each build lands in `releases/<timestamp>-<sha>/` and a
  symlink is flipped in one rename. The site is never half-published.
- **Instant rollback.** Previous builds stay on disk, so going back is a symlink
  flip — no rebuild, no git, no npm.
- **Change detection.** It asks the server what changed before building, and
  skips environments that are already current.
- **Branch verification.** A typo'd branch or expired token is caught before
  anything touches the server.
- **Free HTTPS**, auto-renewing, via Let's Encrypt.
- **SPA routing** — deep links return the app, not a 404.
- **Cache headers done right** — hashed assets cached for a year, `index.html`
  never cached, so users don't run a stale bundle after a deploy.
- **Guards** — refuses to build without disk space, aborts if the build output
  has no `index.html`, warns on domain clashes, and never deletes a path it
  cannot validate.

---

# 1. Setup

## Deploy production only

```bash
./react-develop.sh setup
```

Answer **1** to "How many environments?". Full guide: [SETUP.md](SETUP.md).

## Deploy production AND develop

```bash
./react-develop.sh setup
```

Answer **2**. Environment 1 asks everything; environment 2 inherits the server,
key, repo and token and only asks what differs — name, branch, domain, env file.

Then provision both on the server:

```bash
./react-develop.sh setup all
```

## Provision just one

```bash
./react-develop.sh setup main
```

```bash
./react-develop.sh setup develop
```

## Add another environment later

```bash
./react-develop.sh setup staging
```

## See what is configured

```bash
./react-develop.sh envs
```

---

# 2. Update — the daily loop

## Pick from a menu

```bash
./update.sh
```

## Update one environment

```bash
./update.sh develop
```

```bash
./update.sh main
```

## Update every environment

```bash
./update.sh all
```

Stops at the first failure rather than pushing a broken build onward.

## See what would change, without deploying

```bash
./update.sh --check
```

## Rebuild even though nothing changed

```bash
./update.sh --force develop
```

For when the code is unchanged but the build should run anyway — a build that
died halfway, or an env file edited by hand.

**It checks before it builds.** Nothing changed → it says so and offers to skip:

```
==> develop — branch develop -> dev.example.com
  ✓ develop is already up to date (ca4d58a) — nothing to deploy
  Rebuild and republish anyway? (y/N):
```

Something changed → you see exactly what first:

```
    14 files changed in 3 commits   ca4d58a -> 9f21bc4
      M  src/App.tsx
      A  src/components/Chart.tsx
      … and 11 more
```

Full guide: [UPDATE.md](UPDATE.md).

---

# 3. Environment variables

Each environment reads its own file, auto-detected — nothing to configure:

```
.env.main       VITE_SITE_URL=https://example.com
.env.develop    VITE_SITE_URL=https://dev.example.com
```

## Edit and apply

```bash
./edit-env.sh develop
```

Opens the file in Notepad, **waits until you save and close it**, shows a diff,
then uploads and rebuilds.

## Just look at it

```bash
./edit-env.sh --show main
```

**A rebuild is always required.** Vite compiles `VITE_*` into the JavaScript
bundle at build time — there is no running process holding them, so restarting
nothing would change nothing.

**`VITE_*` values are public.** They ship inside the bundle and anyone can read
them. Never put a secret in one. Full guide: [EDIT-ENV.md](EDIT-ENV.md).

---

# 4. Verify a deploy worked

## Live release, disk, memory, last commit

```bash
./react-develop.sh status develop
```

## Watch this site's nginx logs

```bash
./react-develop.sh logs develop
```

## List releases on the server

```bash
./react-develop.sh releases develop
```

## Confirm the site answers

```bash
curl -I https://your-domain
```

## Confirm SPA deep links don't 404

```bash
curl -o /dev/null -s -w "%{http_code}\n" https://your-domain/some/route
```

`200` is correct — nginx falls unknown paths through to `index.html`.

## Confirm cache headers

```bash
curl -sI https://your-domain/ | grep -i cache-control
```

`index.html` must be `no-cache`; hashed assets under `/assets/` should be
`public, immutable`.

---

# 5. When something goes wrong

## Roll back to the previous release

```bash
./react-develop.sh rollback develop
```

Seconds, because the old build is still on disk. The next `./update.sh` builds
from git again and moves forward.

## Reload nginx

```bash
./react-develop.sh restart develop
```

## Get a shell on the server

```bash
./react-develop.sh ssh develop
```

## Re-issue or renew HTTPS

```bash
./react-develop.sh ssl develop
```

## Change any saved answer

```bash
./react-develop.sh config develop
```

Every prompt is pre-filled. **Enter** keeps a value; **`-`** clears one to empty.

---

# 6. Housekeeping

## Delete an environment — preview first

```bash
./remove-env.sh --dry-run develop
```

## Delete it

```bash
./remove-env.sh develop
```

Makes you type the environment name, and asks about the server separately so you
can drop a local config without taking a live site down.
Full guide: [REMOVE-ENV.md](REMOVE-ENV.md).

## Point the SSH firewall rule at your current IP

```bash
./react-develop.sh allow-ip
```

## Harden the server

```bash
./react-develop.sh harden
```

fail2ban, unattended security updates, sshd lockdown, swap.

## All commands

```bash
./react-develop.sh help
```

---

# 7. How it works

```
your laptop                    the VPS
───────────                    ───────
./update.sh develop  ──SSH──▶  git fetch + reset --hard origin/develop
                               restore the uploaded .env
                               npm ci
                               npm run build
                               dist/ ──▶ /var/www/<site>/releases/<ts>-<sha>/
                                              │
                               current ───────┘   ← symlink flipped atomically
                                              │
                               nginx serves ──┘
```

**The build happens on the server.** You never upload `dist/`.

**nginx serves files from disk** — no pm2, no Node process, no port. That is how
static frontends are served in production, and it means nothing can crash.

## On the server

```
/home/ubuntu/apps/<site>/              git checkout + node_modules
/var/www/<site>/releases/<ts>-<sha>/   one build
/var/www/<site>/current -> releases/…  the symlink nginx reads
/etc/nginx/sites-available/<site>      the server block
/var/log/nginx/<site>.access.log       this site's logs only
```

The newest 5 releases are kept, then pruned.

## In this folder

| File | Purpose |
|---|---|
| `react-develop.<env>.conf` | that environment's answers — **holds your git token** |
| `.env.<env>` | that environment's build variables |

Both are gitignored, along with `*.bak` and `*.pem`. They must stay beside the
scripts — the scripts look for them next to themselves.

## A different project on the same server

```bash
CONFIG_FILE=./portal.conf ./react-develop.sh setup
```

Only the site name and domain must differ. React sites use no port, so there is
nothing to allocate and nothing to collide.

---

# 8. Troubleshooting

| Symptom | Cause |
|---|---|
| `command not found` | missing `./`, or you're in PowerShell instead of Git Bash |
| `Permission denied` | `chmod +x react-develop.sh`, or run `bash react-develop.sh …` |
| `$'\r': command not found` | CRLF line endings — `dos2unix react-develop.sh` |
| `Several environments exist` | name one: `./update.sh develop` |
| `'main' is an environment, not a command` | put the command first: `setup main` |
| Branch "does NOT exist" | the real list is shown — pick from it |
| certbot fails | DNS isn't pointing here yet; fix the A record, then `ssl <env>` |
| Build killed with no error | out of RAM or disk — `status` reports both |
| Site shows an old version | hard-refresh; `index.html` is `no-cache` but your browser may hold the page |
