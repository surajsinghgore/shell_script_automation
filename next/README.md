# Next.js (SSR) → VPS deployment

CI/CD for a **server-rendered** Next.js app on your own server — API routes,
server components, ISR and all. Push to GitHub, run one command, the server
builds it, pm2 runs it and nginx proxies to it.

Everything runs **from your laptop in Git Bash** over SSH. No CI service
involved.

```bash
cd /c/Users/suraj/Downloads/vps/next
```

> **Requires `output: "standalone"` in `next.config.ts`.** Without it the deploy
> stops with a clear error instead of publishing a broken site.

---

## Contents

| Doc | Script | Covers |
|---|---|---|
| [SETUP.md](SETUP.md) | `next-deploy.sh` | first-time setup, one or many environments |
| [UPDATE.md](UPDATE.md) | `update.sh` | the daily loop after you push |
| [EDIT-ENV.md](EDIT-ENV.md) | `edit-env.sh` | change variables, restart or rebuild |
| [REMOVE-ENV.md](REMOVE-ENV.md) | `remove-env.sh` | delete an environment |

---

## What you get

- **One command per deploy.** `git push`, then `./update.sh`.
- **Multiple environments** — each with its own branch, domain, **port**, pm2
  process and release history.
- **Full SSR support** — API routes, server actions, middleware, streaming,
  dynamic routes. Verified end to end, see [§4](#4-verify-a-deploy-worked).
- **Atomic releases + instant rollback.** Old builds stay on disk, so going back
  is a symlink flip plus a pm2 restart.
- **Restart vs rebuild, decided for you.** Server-side variables apply in
  seconds; only `NEXT_PUBLIC_*` forces a full rebuild.
- **Standalone assembly done correctly** — Next.js does *not* copy
  `.next/static` or `public/` into `standalone`; the deploy does, so your CSS
  and images actually load.
- **Change detection** before building, so a no-op deploy costs seconds.
- **Free auto-renewing HTTPS.**
- **Guards** — disk-space checks sized to real measurements, port-clash
  detection, swap that is never destroyed to make room for itself, and a build
  that aborts rather than publishing something broken.

---

# 1. Setup

## Deploy production only

```bash
./next-deploy.sh setup
```

Answer **1** to "How many environments?". Full guide: [SETUP.md](SETUP.md).

## Deploy production AND develop

```bash
./next-deploy.sh setup
```

Answer **2**. Ports auto-increment (3000, 3001…) and are checked for clashes.

Then provision both:

```bash
./next-deploy.sh setup all
```

## Provision just one

```bash
./next-deploy.sh setup main
```

```bash
./next-deploy.sh setup develop
```

## Add another environment later

```bash
./next-deploy.sh setup staging
```

## See what is configured

```bash
./next-deploy.sh envs
```

> **Budget per environment: ~250 MB RAM and ~660 MB disk**, plus ~1.3 GB free
> during a *first* deploy. Two Next.js environments do not fit on an 8 GB
> volume. `status` reports both.

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

## See what would change, without deploying

```bash
./update.sh --check
```

## Rebuild even though nothing changed

```bash
./update.sh --force main
```

Nothing changed → it offers to skip instead of wasting five minutes:

```
  ✓ main is already up to date (ca4d58a) — nothing to deploy
  Rebuild and republish anyway? (y/N):
```

Something changed → you see what first:

```
    14 files changed in 3 commits   ca4d58a -> 9f21bc4
      M  app/page.tsx
      A  app/api/search/route.ts
```

It also spots the **rolled-back** case, where the code is current but the *live
release* is older. Full guide: [UPDATE.md](UPDATE.md).

---

# 3. Environment variables

Each environment reads its own file, auto-detected:

```
.env.main       NEXT_PUBLIC_SITE_URL=https://example.com     DATABASE_URL=…
.env.develop    NEXT_PUBLIC_SITE_URL=https://dev.example.com DATABASE_URL=…
```

## Edit and apply

```bash
./edit-env.sh main
```

Opens Notepad, **waits until you save and close**, shows a diff, then works out
which action is needed:

| You changed | Action | Time |
|---|---|---|
| `NEXT_PUBLIC_*` | full rebuild — it is compiled into the browser bundle | ~3 min |
| anything else | pm2 restart — read from the environment at runtime | ~5 s |

```
    only server-side variables changed — a restart is enough (seconds, not minutes)
  Restart main now? (Y/n, or 'b' to rebuild anyway):
```

## Just look at it

```bash
./edit-env.sh --show main
```

**Secrets are fine here** — database URLs, API keys — as long as they are *not*
prefixed `NEXT_PUBLIC_`. That prefix is what compiles a value into the
JavaScript everyone downloads. The script warns if a `NEXT_PUBLIC_` name looks
secret. Full guide: [EDIT-ENV.md](EDIT-ENV.md).

---

# 4. Verify a deploy worked

## pm2 state, live release, port health, disk, memory

```bash
./next-deploy.sh status main
```

## Watch the app's logs — where a crash shows up

```bash
./next-deploy.sh logs main
```

## List releases

```bash
./next-deploy.sh releases main
```

## Confirm the site answers

```bash
curl -I https://your-domain
```

## Confirm an API route works

```bash
curl -s https://your-domain/api/health
```

If your app exposes a health/status route, this is the honest check that a
deploy picked up its environment — it reports whether secrets are *set* without
printing them.

## Confirm dynamic rendering, not a cached shell

```bash
curl -s https://your-domain/ | grep -c "<article"
```

**Verified working through this nginx config:** all HTTP methods, nested dynamic
paths, query strings, JSON bodies, `Authorization` and `Cookie` forwarding,
5 MB uploads, 413 on oversized ones, and incremental streaming for SSE.

---

# 5. When something goes wrong

## Roll back to the previous release

```bash
./next-deploy.sh rollback main
```

Symlink flip plus a pm2 restart — seconds, no rebuild. It health-checks the port
afterwards so you know it came back.

## Restart the Node process

```bash
./next-deploy.sh restart main
```

## Get a shell on the server

```bash
./next-deploy.sh ssh main
```

## Re-issue or renew HTTPS

```bash
./next-deploy.sh ssl main
```

## Rewrite the nginx block

```bash
./next-deploy.sh nginx main
```

## Change any saved answer

```bash
./next-deploy.sh config main
```

Pre-filled. **Enter** keeps a value; **`-`** clears one to empty.

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

Stops the pm2 process **before** deleting files — otherwise pm2 crash-loops on a
`server.js` that no longer exists. Full guide: [REMOVE-ENV.md](REMOVE-ENV.md).

## Point the SSH firewall rule at your current IP

```bash
./next-deploy.sh allow-ip
```

## Harden the server

```bash
./next-deploy.sh harden
```

## All commands

```bash
./next-deploy.sh help
```

---

# 7. How it works

```
your laptop                    the VPS
───────────                    ───────
./update.sh main     ──SSH──▶  git fetch + reset --hard origin/main
                               restore the uploaded .env
                               npm ci
                               next build            -> .next/standalone
                               assemble release      -> + .next/static + public
                                     │
                               current ──┘  symlink flipped
                                     │
                               pm2 restart ──▶ node server.js  :3000
                                     │
                               nginx :80/:443 ──proxy──┘
```

**Expect ~1–2 s of 502s during a deploy** — the process has to stop and start.
The static React sites don't do this because nothing is running to restart.

**A failed build changes nothing** — the symlink never moves and the old process
keeps serving.

## On the server

```
/home/ubuntu/apps/<site>/              git checkout + full node_modules
/var/www/<site>/releases/<ts>-<sha>/   one assembled standalone bundle
/var/www/<site>/current -> releases/…  the symlink pm2 runs from
/var/www/<site>/start.sh               pm2 wrapper (sets PORT, loads env)
/var/www/<site>/ecosystem.config.cjs   pm2 config
/var/www/<site>/.env.export            runtime vars, shell-quoted, chmod 600
/etc/nginx/sites-available/<site>      the server block
/var/log/nginx/<site>.access.log       this site's logs only
```

The newest **3** releases are kept — a standalone bundle is far larger than a
folder of static files.

## nginx routing

| Location | Behaviour |
|---|---|
| `/_next/static/` | proxied, cached 1 year, `immutable`, exempt from rate limits |
| `/_next/image` | proxied, cached 30 days |
| `/api/` | own rate zone (150 r/s, burst 300), `proxy_buffering off` for streaming |
| `/` | proxied, 30 r/s with burst 60 |

`/api/` needs its own budget: one dashboard render can fire 30 parallel fetches,
which a page-sized limit would reject as an attack.

## In this folder

| File | Purpose |
|---|---|
| `next-deploy.<env>.conf` | that environment's answers — **holds your git token** |
| `.env.<env>` | that environment's variables |

Both gitignored. They must stay beside the scripts.

## Differences from the React tooling

| | React SPA (`../react/`) | Next.js SSR (here) |
|---|---|---|
| What runs | nothing — nginx reads files | `node server.js` under pm2 |
| Port | none | **one per environment** |
| Env change | always a rebuild | usually a restart |
| Deploy downtime | none | ~1–2 s |
| Releases kept | 5 | 3 |
| Cost per env | ~120 MB disk | ~250 MB RAM, ~660 MB disk |

---

# 8. Troubleshooting

| Symptom | Cause |
|---|---|
| `command not found` | missing `./`, or you're in PowerShell instead of Git Bash |
| `$'\r': command not found` | CRLF line endings — `dos2unix next-deploy.sh` |
| `.next/standalone missing` | add `output: "standalone"` to `next.config` |
| `'main' is an environment, not a command` | put the command first: `setup main` |
| `Several environments exist` | name one: `./update.sh main` |
| Build "Killed" with no error | out of RAM — the script adds swap, but check disk too |
| `no response on :PORT` | the app crashed on boot — `logs <env>` |
| 502 from nginx | the Node process is down — `status <env>` |
| Port already listening | another process owns it — `config <env>` and pick another |
| certbot fails | DNS isn't pointing here yet; fix the A record, then `ssl <env>` |
| Site builds but shows no data | check the API keys actually landed: `curl .../api/health` |
