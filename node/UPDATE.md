# Update — you pushed code, now publish it

Setup is a one-time thing. This is the loop you'll live in.

```bash
cd /c/Users/suraj/Downloads/vps/next
./update.sh
```

---

## The menu

```
  #    ENVIRONMENT              BRANCH       PORT    DOMAIN
  ---  -----------              ------       ----    ------
  1)   develop                  develop      3001    dev.example.com
  2)   production               main         3000    example.com

  Which one? (number, name, or 'all'):
```

Built from your `node-deploy.<name>.conf` files, so it always matches what's
configured. Add a third environment later and it appears here automatically.

## Or skip the menu

```bash
./update.sh develop        # pulls the develop branch -> develop domain
./update.sh production     # pulls main -> live domain
./update.sh 2              # by number
./update.sh all            # every environment, in turn
./update.sh --check        # what WOULD change, everywhere. Deploys nothing
./update.sh --force main   # rebuild even if nothing changed
./update.sh --list         # show the table, change nothing
```

**Each environment tracks its own branch.** You never pass it, and you can't get
them crossed. `all` stops at the first failure rather than pushing a broken
build onward.

---

## It checks before it builds

Every run first asks the server how far behind it is — one SSH round trip that
fetches refs only. No checkout, no build, nothing on the live site touched.

**Nothing changed → it asks rather than wasting five minutes:**

```
==> develop — branch develop on :3001 -> dev.example.com
  ✓ develop is already up to date (ca4d58a) — nothing to deploy
  Rebuild and republish anyway? (y/N):
```

**Something changed → you see what, then it builds:**

```
    14 files changed in 3 commits   ca4d58a -> 9f21bc4
    14 files changed, 248 insertions(+), 96 deletions(-)
      M  app/page.tsx
      A  app/api/search/route.ts
      … and 11 more
```

### Cases it recognises

| Situation | What it does |
|---|---|
| Behind the remote | shows counts and files, deploys |
| Already current | asks whether to rebuild anyway |
| Never deployed | clones and builds |
| **Rolled back** | warns that code is current but the live release is older, deploys forward |
| Server unreachable | skips — `--force` overrides |

---

## What a deploy actually does

```
git fetch + reset --hard origin/<branch>
restore the uploaded .env          ← git reverts a tracked .env; this puts yours back
npm ci
next build                         ← 3 GB swap ensured first
copy app -> releases/<ts>-<sha>/   ← everything except .git
flip current symlink
pm2 restart                        ← ~1-2s of downtime
health check on 127.0.0.1:PORT     ← waits up to 40s
prune to the newest 3 releases
```

Typically 2–5 minutes, mostly `npm ci` and the build.

**There is a brief interruption.** Unlike the static React sites, this is a
process that has to stop and start — expect roughly a second where nginx returns
502. A failed *build* changes nothing, though: the symlink never moves and the
old process keeps serving.

Only 3 releases are kept, not 5 — each one carries its own `node_modules`.

---

## Changed a variable?

```bash
./edit-env.sh develop
```

It works out whether a **restart** (seconds) or a **rebuild** (minutes) is
needed, based on whether any `environment variables` key changed. See
[EDIT-ENV.md](EDIT-ENV.md).

---

## Something broke — go back

```bash
./node-deploy.sh rollback develop
```

Flips `current` to the previous release and restarts pm2. **No rebuild, no git,
no npm** — a few seconds, because the old bundle is still on disk. It then
health-checks the port so you know it actually came back.

```bash
./node-deploy.sh releases develop
```

```
-> 20260725-140544-fd37fc1   210M      ← live
   20260725-131102-a91be03   210M
```

---

## Checking on things

```bash
./node-deploy.sh status develop    # pm2 state, live release, port health, disk, memory
./node-deploy.sh logs develop      # pm2 logs — where a crash shows up
./node-deploy.sh restart develop   # restart the process
./node-deploy.sh ssh develop       # shell on the server, in the checkout
```

`status` is worth a glance after each deploy. A high **restart count** means the
process is crash-looping — `logs` will show why.

Watch **disk and memory**: each environment carries its own `node_modules`,
3 releases, and a live process. Disk is what runs out first.

---

## Common questions

**Do I need to build locally first?**
No. Push to GitHub, then `./update.sh`. The build happens on the server.

**Do I have to commit before updating?**
Yes — it deploys `origin/<branch>`. Unpushed work is invisible to it.

**Why did my site 502 for a second?**
Expected. pm2 restarts the process on deploy. The static React sites don't do
this because nothing is running to restart.

**Does updating one environment affect the other?**
No. Separate ports, pm2 processes, checkouts, releases and nginx blocks.

**Can two people update at once?**
Don't. There's no lock, and two builds in the same checkout will fight.
