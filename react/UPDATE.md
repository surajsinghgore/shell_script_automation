# Update — you pushed code, now publish it

Setup is a one-time thing. This is the loop you'll actually live in.

```bash
cd /c/Users/suraj/Downloads/vps/react
./update.sh
```

---

## The menu

Run with no argument and it reads your configured environments and asks:

```
  #    ENVIRONMENT              BRANCH       DOMAIN
  ---  -----------              ------       ------
  1)   develop                  develop      develop-surajsinghweather.surajsingh.online
  2)   main                     main         surajsinghweather.surajsingh.online

  Which one? (number, name, or 'all'):
```

Type `1`, or `develop`, or `all`. The list is generated from the
`react-develop.<name>.conf` files that setup created — add a third environment
later and it appears here automatically, no edits needed.

## Or skip the menu

```bash
./update.sh develop        # pulls the develop branch -> develop domain
./update.sh main           # pulls the main branch    -> main domain
./update.sh staging        # whatever you named it
./update.sh 2              # by number
./update.sh all            # every environment, in turn
./update.sh --check        # what WOULD change, everywhere. Deploys nothing
./update.sh --force main   # rebuild even if nothing changed
./update.sh --list         # show the table and exit, change nothing
```

---

## It checks before it builds

Every run first asks the server how far behind it is — one SSH round trip that
fetches refs only. No checkout, no build, nothing on the live site touched.

**Nothing changed → it doesn't deploy.**

```
==> develop — branch develop -> develop-surajsinghweather.surajsingh.online
  ✓ develop is already up to date (ca4d58a) — nothing to deploy
```

**Something changed → you see what, then it builds.**

```
==> develop — branch develop -> develop-surajsinghweather.surajsingh.online
    14 files changed in 3 commits   ca4d58a -> 9f21bc4
    14 files changed, 248 insertions(+), 96 deletions(-)
      M  src/App.tsx
      A  src/components/Chart.tsx
      D  src/old.ts
      … and 11 more

########  deploying develop  ########
```

The file list is capped at 12 with a count of the rest.

`./update.sh all` checks each one and only builds what's actually behind, so
running it out of habit costs seconds instead of minutes per environment.

### Have a look without committing to anything

```bash
./update.sh --check
```

Reports on every environment and deploys nothing. Useful before a release to see
what's queued up.

### Cases it recognises

| Situation | What it does |
|---|---|
| Behind the remote | shows the counts and file list, deploys |
| Already current | skips, says so |
| Never deployed | clones and builds |
| **Rolled back** | warns that code is current but the *live release* is older, and deploys to move forward |
| Server unreachable | skips rather than guessing — `--force` overrides |

That rollback case is worth knowing. After `rollback`, the checkout is still at
the newest commit while the site serves an older build, so a naive "is the code
current?" check would wrongly say there is nothing to do.

### Forcing a rebuild

```bash
./update.sh --force develop
```

For when the code hasn't changed but the build should still run — you edited
`.env.develop` by hand, or a previous build failed halfway.

**Each environment tracks its own branch.** `./update.sh develop` pulls
`develop`; `./update.sh main` pulls `main`. The branch is stored per
environment at setup — you never pass it, and you can't get them crossed.

`all` stops at the first failure rather than pushing a broken build onward.

---

## What happens

```
git fetch + reset --hard origin/<branch>   ← exactly what you pushed
restore the uploaded .env                  ← git reverts a tracked .env; this puts yours back
npm ci
npm run build
dist/ → releases/<timestamp>-<sha>/
current symlink flipped                    ← atomic
prune to the newest 5 releases
```

Roughly 1–3 minutes, most of it `npm ci` and the build.

**Your site stays up the whole time.** The new build is assembled in a fresh
directory; visitors keep hitting the old one until the symlink flips, which is a
single atomic rename. There is no window where the site is half-published.

**A failed build changes nothing.** If `npm run build` fails, or `dist/` has no
`index.html`, the symlink never moves and the previous release keeps serving.

---

## Changed an environment variable?

```bash
./edit-env.sh              # menu
./edit-env.sh develop      # or straight to one
```

What it does:

1. Opens `.env.develop` in Notepad (or `$EDITOR`)
2. **Waits until you save and close it** — nothing is uploaded half-typed
3. Shows a diff of exactly what changed
4. Warns about lines that aren't `KEY=value`, and about secret-looking names
5. Asks to confirm, then uploads and **rebuilds**

A rebuild is required — a restart does nothing. Vite inlines `VITE_*` into the
JavaScript bundle at build time; there is no running process holding them, since
nginx only serves files.

```bash
./edit-env.sh --show main   # just print it, change nothing
```

If the file doesn't exist yet, it offers to start from your app's `.env`.

## Removing an environment

```bash
./remove-env.sh --dry-run develop   # see exactly what would be destroyed
./remove-env.sh develop             # do it
```

It lists everything that will go — local config, nginx block, every release, the
checkout, the logs — then makes you **type the environment name** to confirm.
Deleting from the server is a separate yes/no, so you can drop a local config
without taking a live site down.

Kept deliberately: the TLS certificate (it costs nothing, and re-issuing burns
Let's Encrypt rate limit) and every other site on the box.

---

## Something went wrong — go back

```bash
./react-develop.sh rollback develop
```

Flips `current` to the previous release and reloads nginx. **No rebuild, no git,
no npm** — a few seconds, because the old build is still on disk.

```bash
./react-develop.sh releases develop
```

```
-> 20260725-140544-fd37fc1   1.2M      ← live
   20260725-131102-a91be03   1.2M
   20260725-102233-77c1de9   1.2M
```

The last 5 are kept. `rollback` twice steps back twice.

Rollback is a stopgap: the next `./update.sh` builds from git again and moves
forward, so fix the actual problem and push.

---

## Checking on things

```bash
./react-develop.sh status develop     # live release, file count, disk, memory, last commit
./react-develop.sh logs develop       # tail this site's nginx access + error logs
./react-develop.sh ssh develop        # shell on the server, in the checkout
```

`status` reports disk — worth a glance now and then. Each environment carries
its own `node_modules` (~120 MB) plus 5 releases, and the build swapfile takes
2 GB. Disk is the resource that runs out first on a small instance.

---

## Certificates

Auto-renewing — certbot installed a timer at setup. Nothing to do.

Needed only if you skipped HTTPS because DNS wasn't ready:

```bash
./react-develop.sh ssl develop
```

---

## Common questions

**Do I need to build locally first?**
No. Push to GitHub, then `./update.sh`. The build happens on the server, from
whatever the branch's tip is.

**Do I have to commit before updating?**
Yes — it deploys `origin/<branch>`, not your working directory. Uncommitted or
unpushed work is invisible to it.

**Can I deploy a different branch temporarily?**
`./react-develop.sh config <env>` and change the branch. It's verified against
the repo before anything runs. Change it back afterwards.

**Does updating one environment affect the other?**
No. Separate checkouts, separate `/var/www` directories, separate nginx blocks,
separate release histories. The ClinicCare backend is untouched too — these
scripts never go near pm2.

**What if two people update at once?**
Don't. There's no lock; two concurrent builds in the same checkout will fight.
