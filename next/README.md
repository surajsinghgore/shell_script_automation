# Next.js deployment on the VPS

Deploying a **server-rendered** Next.js app — one branch per environment, each
on its own domain and port, sharing the server with the other sites.

| Doc | Script | What it covers |
|---|---|---|
| [SETUP.md](SETUP.md) | `next-deploy.sh` | First-time setup — from nothing to a live HTTPS site |
| [UPDATE.md](UPDATE.md) | `update.sh` | After you push code: pull, rebuild, republish |
| [EDIT-ENV.md](EDIT-ENV.md) | `edit-env.sh` | Change an environment's variables and apply them |
| [REMOVE-ENV.md](REMOVE-ENV.md) | `remove-env.sh` | Delete an environment (destructive — read first) |

## The four scripts

All run **from your laptop** in Git Bash and talk to the server over SSH.

```bash
cd /c/Users/suraj/Downloads/vps/next
```

The last three open with the same numbered menu, so you never have to remember
names:

```
  #    ENVIRONMENT              BRANCH       PORT    DOMAIN
  ---  -----------              ------       ----    ------
  1)   develop                  develop      3001    dev.example.com
  2)   production               main         3000    example.com
```

Or name it directly: `./update.sh develop`, `./edit-env.sh 2`.

## How this differs from the React SPA setup

The `react/` tooling deploys static files. This is a **running Node process**,
and almost every difference follows from that.

| | React SPA (`react/`) | Next.js SSR (here) |
|---|---|---|
| What runs | nothing — nginx reads files | `node server.js` under pm2 |
| nginx | serves from disk | reverse-proxies to `127.0.0.1:PORT` |
| Port | none | **one per environment**, must be unique |
| Env vars | all baked in at build | `NEXT_PUBLIC_*` baked in; the rest are runtime |
| Changing a var | always a rebuild | usually just a **restart** |
| Rollback | flip a symlink | flip a symlink + pm2 restart |
| Cost per env | ~120 MB disk | **~250 MB RAM, ~600 MB disk** |

That last row matters on a small instance. Check `./next-deploy.sh status`
before adding a second environment.

## How it works

```
your laptop                    the VPS
───────────                    ───────
./update.sh develop  ──SSH──▶  git pull  (develop branch)
                               npm ci
                               npm run build          -> .next/standalone
                               assemble release       -> + .next/static + public
                                     │
                               current ──┘  symlink flipped
                                     │
                               pm2 restart ──▶ node server.js  :3001
                                     │
                               nginx :80/:443 ──proxy──┘
```

**The standalone assembly step is not optional.** `output: "standalone"` emits
`server.js` with a minimal `node_modules`, but Next.js does **not** copy
`.next/static` or `public/` into it. Skip that and the site loads with no CSS,
no JS chunks and no images. The deploy does it for you.

## Where things live on the server

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

## Files in this folder

| File | Purpose |
|---|---|
| `next-deploy.<env>.conf` | that environment's answers — **holds your git token** |
| `.env.<env>` | that environment's variables |

Both are gitignored. They must stay beside the scripts — the scripts look for
them next to themselves.

## Quick reference

```bash
./update.sh                        # menu: pick an environment to update
./update.sh develop                # update just develop
./update.sh --check                # what WOULD change, deploys nothing
./update.sh --force develop        # rebuild even if nothing changed

./edit-env.sh develop              # edit variables, then restart or rebuild
./edit-env.sh --show develop

./remove-env.sh --dry-run develop  # show what deleting would destroy
./remove-env.sh develop

./next-deploy.sh status develop    # pm2, live release, port health, disk
./next-deploy.sh logs develop      # pm2 logs
./next-deploy.sh restart develop   # restart the Node process
./next-deploy.sh releases develop
./next-deploy.sh rollback develop
./next-deploy.sh ssl develop
./next-deploy.sh envs
./next-deploy.sh help
```
