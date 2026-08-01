# Node.js API / backend → VPS deployment

CI/CD for a Node backend — Express, Nest, Fastify, a plain HTTP server — on your
own machine. Push to GitHub, run one command, the server installs, builds if
needed, and pm2 restarts behind nginx.

Everything runs **from your laptop in Git Bash** over SSH.

```bash
cd /c/Users/suraj/Downloads/vps/node
```

---

## Contents

| Doc | Script | Covers |
|---|---|---|
| [SETUP.md](SETUP.md) | `node-deploy.sh` | first-time setup, one or many environments |
| [UPDATE.md](UPDATE.md) | `update.sh` | the daily loop after you push |
| [EDIT-ENV.md](EDIT-ENV.md) | `edit-env.sh` | change variables and restart |
| [REMOVE-ENV.md](REMOVE-ENV.md) | `remove-env.sh` | delete an environment |

---

## What you get

- **One command per deploy.** `git push`, then `./update.sh`.
- **Multiple environments** — each with its own branch, domain, **port**, pm2
  process and release history.
- **Atomic releases + instant rollback.** The whole prepared app becomes a
  release; going back is a symlink flip plus a pm2 restart, with no reinstall.
- **Env changes apply in seconds.** A backend reads its variables at startup, so
  a restart is enough — there is nothing to recompile.
- **Real secrets belong here.** Nothing in a backend `.env` reaches a browser,
  unlike the React and Next.js toolchains.
- **Change detection** before deploying, so a no-op costs seconds.
- **Branch verification** against the git host before anything touches the box.
- **Free auto-renewing HTTPS.**
- **Guards** — disk checks sized to a backend, port-clash detection, safe
  `.env` parsing, pm2 stopped before files are removed.

---

# 1. Setup

## Deploy production only

```bash
./node-deploy.sh setup
```

Answer **1** to "How many environments?". Full guide: [SETUP.md](SETUP.md).

## Deploy production AND develop

```bash
./node-deploy.sh setup
```

Answer **2**. Ports auto-increment and are checked for clashes.

```bash
./node-deploy.sh setup all
```

## Provision just one

```bash
./node-deploy.sh setup main
```

```bash
./node-deploy.sh setup develop
```

## See what is configured

```bash
./node-deploy.sh envs
```

## The three commands that matter at setup

| Prompt | Example | Notes |
|---|---|---|
| Install command | `npm ci \|\| npm install` | keep dev deps — TS/build tooling lives there |
| Build command | *blank*, or `npm run build` | blank is fine; plain JS APIs have no build |
| **Start command** | `npm start`, `node server.js`, `node dist/main.js` | what pm2 actually runs |

> Budget roughly **150 MB RAM and 320 MB disk** per environment.

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

## Redeploy even though nothing changed

```bash
./update.sh --force main
```

Full guide: [UPDATE.md](UPDATE.md).

---

# 3. Environment variables

Each environment reads its own file, auto-detected:

```
.env.main       DATABASE_URL=postgres://…/prod   JWT_SECRET=…
.env.develop    DATABASE_URL=postgres://…/dev    JWT_SECRET=…
```

## Edit and apply

```bash
./edit-env.sh main
```

Opens the file, waits for you to save and close, shows a diff, then **restarts**
— seconds, because a backend reads its environment at startup.

## Just look at it

```bash
./edit-env.sh --show main
```

**Secrets are appropriate here.** Database URLs, JWT secrets, API keys — none of
it reaches a browser. The file is `chmod 600` on both ends and gitignored, and
the runtime copy on the server (`/var/www/<site>/.env.export`) is too.

Answer **`b`** at the prompt if your build bakes a value in and you need a full
redeploy instead. Full guide: [EDIT-ENV.md](EDIT-ENV.md).

---

# 4. Verify a deploy worked

## pm2 state, live release, port health, disk, memory

```bash
./node-deploy.sh status main
```

## Watch the app's logs — where a crash shows up

```bash
./node-deploy.sh logs main
```

## List releases

```bash
./node-deploy.sh releases main
```

## Confirm the API answers

```bash
curl -i https://your-domain/
```

## Confirm a specific route

```bash
curl -s https://your-domain/api/health
```

## Confirm it survived a restart

```bash
./node-deploy.sh status main | grep -E "status|restarts"
```

A climbing **restart count** means the process is crash-looping — `logs` shows
why. Typically a missing env var or a database it cannot reach.

---

# 5. When something goes wrong

## Roll back to the previous release

```bash
./node-deploy.sh rollback main
```

Symlink flip plus a pm2 restart. No reinstall, no git.

## Restart the process

```bash
./node-deploy.sh restart main
```

## Get a shell on the server

```bash
./node-deploy.sh ssh main
```

## Re-issue or renew HTTPS

```bash
./node-deploy.sh ssl main
```

## Change any saved answer

```bash
./node-deploy.sh config main
```

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

## Point the SSH firewall rule at your current IP

```bash
./node-deploy.sh allow-ip
```

## Harden the server

```bash
./node-deploy.sh harden
```

## All commands

```bash
./node-deploy.sh help
```

---

# 7. How it works

```
your laptop                    the VPS
───────────                    ───────
./update.sh main     ──SSH──▶  git fetch + reset --hard origin/main
                               restore the uploaded .env
                               npm ci
                               build (only if BUILD_CMD is set)
                               copy app -> releases/<ts>-<sha>/   (.git excluded)
                                     │
                               current ──┘  symlink flipped
                                     │
                               pm2 restart ──▶ $START_CMD  :PORT
                                     │
                               nginx :80/:443 ──proxy──┘
```

**Expect ~1–2 s of 502s during a deploy** — the process stops and starts.

**A failed build changes nothing** — the symlink never moves and the old process
keeps serving.

## On the server

```
/home/ubuntu/apps/<site>/              git checkout + node_modules
/var/www/<site>/releases/<ts>-<sha>/   one complete app copy
/var/www/<site>/current -> releases/…  the symlink pm2 runs from
/var/www/<site>/start.sh               pm2 wrapper (sets PORT, loads env)
/var/www/<site>/.env.export            runtime vars, shell-quoted, chmod 600
/etc/nginx/sites-available/<site>      the server block
/var/log/nginx/<site>.access.log       this site's logs only
```

The newest **3** releases are kept.

## nginx

Every path is proxied to the app — a backend has no static assets and no page
routes, so there is nothing to special-case. One generous rate budget
(150 r/s, burst 300) because a single frontend page can fire 20–30 parallel
calls, and `proxy_buffering off` so streamed responses and downloads reach the
client as they are produced.

## Differences from the frontend toolchains

| | React SPA | Next.js SSR | **Node API (here)** |
|---|---|---|---|
| What runs | nothing | `node server.js` | **your `START_CMD`** |
| Port | none | one per env | **one per env** |
| Env change | rebuild | restart or rebuild | **restart, always** |
| Secrets in `.env` | never | server-side only | **yes, all of it** |
| Build step | required | required | **optional** |
| Disk per env | ~120 MB | ~660 MB | **~320 MB** |

---

# 8. Troubleshooting

| Symptom | Cause |
|---|---|
| `command not found` | missing `./`, or you're in PowerShell not Git Bash |
| `$'\r': command not found` | CRLF endings — `dos2unix node-deploy.sh` |
| `'main' is an environment, not a command` | put the command first: `setup main` |
| `no response on :PORT` | the app crashed on boot — `logs <env>` |
| 502 from nginx | the process is down — `status <env>` |
| Restart count climbing | crash loop; usually a missing env var or unreachable DB |
| Port already listening | another process owns it — `config <env>`, pick another |
| `no node_modules in the release` | the install failed — check the deploy output |
| certbot fails | DNS isn't pointing here yet; fix the A record, then `ssl <env>` |
