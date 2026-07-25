# edit-env.sh — change an environment's variables

Opens one environment's `.env` in your editor, waits for you to save and close
it, shows what changed, then uploads it and rebuilds so the change is actually
live.

```bash
cd /c/Users/suraj/Downloads/vps/react
./edit-env.sh
```

---

## Commands

```bash
./edit-env.sh                 # menu — pick from a numbered list
./edit-env.sh develop         # straight to develop
./edit-env.sh 2               # by number
./edit-env.sh --show main     # print main's file, change nothing
./edit-env.sh --list          # show the table, change nothing
./edit-env.sh --help
```

The menu is built from your `react-develop.<name>.conf` files, so it always
matches what's actually configured:

```
  #    ENVIRONMENT              BRANCH       ENV FILE
  ---  -----------              ------       --------
  1)   develop                  develop      .env.develop
  2)   main                     main         .env.main

  Which environment's variables? (number or name):
```

---

## What happens

```
 1. opens .env.<name> in Notepad         ← or $EDITOR / $VISUAL if you set one
 2. WAITS until you save and close it
 3. exits early if nothing changed
 4. shows a diff of exactly what changed
 5. warns about malformed or secret-looking lines
 6. asks to confirm
 7. uploads the file to the server
 8. REBUILDS and republishes the site
```

Step 2 is the important one — the script blocks rather than racing ahead, so a
half-typed file is never uploaded.

Example:

```
==> Editing .env.develop   (branch develop -> develop-surajsinghweather.surajsingh.online)
    opening Notepad — save and close it to continue

==> What changed
  -VITE_FORECAST_DAYS=7
  +VITE_FORECAST_DAYS=14

==> Applying to develop
    uploading, then rebuilding — Vite bakes these in at build time,
    so a restart alone would change nothing
  Rebuild and publish develop now? (Y/n):
```

Answer `n` and the file stays edited on disk but nothing deploys. Apply it later
with `./edit-env.sh develop` again, or `./update.sh develop`.

---

## Why it rebuilds instead of restarting

This is the thing to understand about a React deploy.

Vite **inlines** `VITE_*` variables into the JavaScript bundle when it builds.
After that they are literal strings inside `assets/index-*.js`. There is no
process holding them — nginx only reads files off disk.

So:

| | Effect |
|---|---|
| Restart nginx | **nothing** — same files, same baked-in values |
| Rebuild | new bundle with the new values, published as a new release |

That is why `edit-env.sh` ends in a rebuild. It takes 1–3 minutes, and your site
stays up throughout — the new build goes to a fresh release directory and the
symlink flips atomically at the end.

---

## One file per environment

```
.env.main        VITE_SITE_URL=https://surajsinghweather.surajsingh.online
.env.develop     VITE_SITE_URL=https://develop-surajsinghweather.surajsingh.online
```

Naming is `.env.<environment name>` and it is auto-detected — nothing to
configure. Editing `.env.develop` cannot affect production.

If an environment has no file of its own it falls back to a shared `.env`, and
the deploy warns:

```
  ! develop is using the shared .env — create .env.develop to give it its own values.
```

Worth heeding. A shared file means develop advertises production's URLs in its
canonical tags and sitemap, and search engines index the wrong site.

If the file doesn't exist yet, `edit-env.sh` offers to seed it from your app's
`.env` so you start from something real rather than a blank page.

---

## Checks it runs

**Malformed lines.** Anything that isn't `KEY=value`, a comment, or blank gets
flagged — it would be silently ignored at build time otherwise:

```
  ! These lines are not KEY=value and will be ignored:
      12: VITE_APP_NAME Suraj Singh Weather
```

**Secret-looking names.** A warning if it sees `SECRET`, `PASSWORD`, `PRIVATE`
or `API_KEY`:

> Everything in this file is compiled into the public JavaScript bundle and
> readable by anyone who opens the site. It is not a secret store. Values that
> must stay private belong on the backend, behind an API.

Note that `.env` values may contain spaces and characters like `&` unquoted —
`VITE_APP_TAGLINE=7-day & hourly forecasts` is valid and handled correctly.

---

## Choosing a different editor

Notepad is the default on Windows. To use something else:

```bash
EDITOR=nano ./edit-env.sh develop
export EDITOR="code --wait"      # VS Code — the --wait matters
```

Without `--wait`, a GUI editor returns immediately and the script would upload
the file before you'd typed anything.

---

## Related

- [UPDATE.md](UPDATE.md) — publishing code changes
- [REMOVE-ENV.md](REMOVE-ENV.md) — deleting an environment
- [SETUP.md](SETUP.md) — first-time setup
