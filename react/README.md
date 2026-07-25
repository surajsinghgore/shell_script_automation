# React deployment on the VPS

Deploying a React (Vite) app to `54.89.160.254` — one branch per environment,
each on its own domain, sharing the server with the ClinicCare Node backend.

| Doc | Script | What it covers |
|---|---|---|
| [SETUP.md](SETUP.md) | `react-develop.sh` | First-time setup — from nothing to a live HTTPS site |
| [UPDATE.md](UPDATE.md) | `update.sh` | After you push code: pull, rebuild, republish |
| [EDIT-ENV.md](EDIT-ENV.md) | `edit-env.sh` | Change an environment's variables and apply them |
| [REMOVE-ENV.md](REMOVE-ENV.md) | `remove-env.sh` | Delete an environment (destructive — read first) |

## The four scripts

Everything lives in this folder and runs **from your laptop** in Git Bash. They
talk to the server over SSH; nothing is installed on your machine.

```bash
cd /c/Users/suraj/Downloads/vps/react
```

| Script | Use it when | Docs |
|---|---|---|
| `react-develop.sh` | first-time setup, and the engine behind the rest | [SETUP.md](SETUP.md) |
| `update.sh` | **daily** — you pushed code, publish it | [UPDATE.md](UPDATE.md) |
| `edit-env.sh` | change an environment's variables | [EDIT-ENV.md](EDIT-ENV.md) |
| `remove-env.sh` | delete an environment | [REMOVE-ENV.md](REMOVE-ENV.md) |

The last three all open with the same numbered menu, so you never have to
remember names:

```
  #    ENVIRONMENT              BRANCH       DOMAIN
  ---  -----------              ------       ------
  1)   develop                  develop      develop-surajsinghweather.surajsingh.online
  2)   main                     main         surajsinghweather.surajsingh.online
```

Or name the environment directly: `./update.sh develop`, `./edit-env.sh 2`.

## What is live now

| Environment | Branch | Domain |
|---|---|---|
| `main` | `main` | https://surajsinghweather.surajsingh.online |
| `develop` | `develop` | https://develop-surajsinghweather.surajsingh.online |

## How it works, in one picture

```
your laptop                    the VPS (54.89.160.254)
───────────                    ───────────────────────
./update.sh develop  ──SSH──▶  git pull  (develop branch)
                               npm ci
                               npm run build
                               dist/ ──▶ /var/www/<site>/releases/<timestamp>-<sha>/
                                              │
                               current ───────┘   ← symlink flipped atomically
                                              │
                               nginx serves ──┘   develop-surajsinghweather…
```

Key points:

- **The build happens on the server**, not your laptop. You never upload `dist/`.
- **nginx serves files from disk.** No pm2, no Node process, no port. That is how
  static frontends are served in production.
- **Every deploy is a new release directory**, and a symlink is flipped in one
  atomic step. The site is never half-published, and the previous build stays on
  disk so `rollback` is instant and needs no rebuild.
- **The last 5 releases are kept**, then pruned.

## Where things live on the server

```
/home/ubuntu/apps/<site>/            git checkout + node_modules
/var/www/<site>/releases/<ts>-<sha>/ one build
/var/www/<site>/current -> releases/…  the symlink nginx reads
/etc/nginx/sites-available/<site>    the server block
/var/log/nginx/<site>.access.log     this site's logs only
```

## Files in this folder

| File | Purpose |
|---|---|
| `react-develop.<env>.conf` | that environment's answers — **holds your git token** |
| `.env.<env>` | that environment's build variables |

Both are gitignored, along with `*.bak`. Neither should ever be committed.
They must stay beside the scripts — the scripts look for them next to
themselves, so moving one without the other breaks the pair.

## Quick reference

```bash
./update.sh                        # menu: pick an environment to update
./update.sh develop                # update just develop
./update.sh all                    # every environment, stops on first failure
./update.sh --check                # what WOULD change, everywhere. Deploys nothing
./update.sh --force main           # rebuild even if nothing changed
./update.sh --list                 # show the table, change nothing

./edit-env.sh                      # menu, then edit + rebuild
./edit-env.sh develop              # edit develop's variables
./edit-env.sh --show main          # print main's file, change nothing

./remove-env.sh --dry-run develop  # show what deleting would destroy
./remove-env.sh develop            # delete it (asks you to type the name)

./react-develop.sh status develop  # what's live, disk, memory, last commit
./react-develop.sh logs develop    # tail nginx access + error logs
./react-develop.sh releases develop
./react-develop.sh rollback develop
./react-develop.sh ssl develop     # issue/renew the certificate
./react-develop.sh envs            # list configured environments
./react-develop.sh help
```
