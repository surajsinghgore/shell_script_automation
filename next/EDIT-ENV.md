# edit-env.sh — change an environment's variables

Opens one environment's `.env` in your editor, waits for you to save and close
it, shows what changed, then applies it — **restarting or rebuilding depending
on which keys you touched**.

```bash
cd /c/Users/suraj/Downloads/vps/next
./edit-env.sh
```

---

## Commands

```bash
./edit-env.sh                    # menu — pick from a numbered list
./edit-env.sh develop            # straight to develop
./edit-env.sh 2                  # by number
./edit-env.sh --show production  # print the file, change nothing
./edit-env.sh --list             # show the table, change nothing
./edit-env.sh --help
```

---

## Restart or rebuild — the thing to understand

Next.js has two kinds of variable, and they cost very different amounts to
change:

| | Where it lives | To apply a change | Takes |
|---|---|---|---|
| `NEXT_PUBLIC_*` | compiled into the **browser bundle** at build time | full rebuild | 2–5 min |
| everything else | read by the **server** at runtime | pm2 restart | ~2 s |

The script diffs the keys you actually changed and picks the cheaper one.

**Server-side variable changed:**

```
==> Applying to develop
    only server-side variables changed — a restart is enough (seconds, not minutes)
  Restart develop now? (Y/n, or 'b' to rebuild anyway):
```

**A `NEXT_PUBLIC_*` changed:**

```
==> Applying to develop
    NEXT_PUBLIC_* changed:
      NEXT_PUBLIC_SITE_URL
    those are compiled into the browser bundle, so this needs a full rebuild
  Rebuild and publish develop now? (Y/n):
```

`b` at the restart prompt forces a rebuild if you want one anyway — for instance
after editing the file by hand outside this script.

> This is the main difference from the React SPA tooling, where *every* variable
> is baked in at build time and a restart is meaningless.

---

## What happens

```
 1. opens .env.<name> in Notepad         ← or $EDITOR / $VISUAL
 2. WAITS until you save and close it
 3. exits early if nothing changed
 4. shows a diff
 5. works out which KEYS changed
 6. warns about malformed lines and risky NEXT_PUBLIC_ names
 7. asks to confirm
 8. uploads, then restarts or rebuilds
```

Step 2 is the important one — nothing is uploaded half-typed.

---

## Secrets

Unlike a React SPA, **this file can legitimately hold secrets** — database URLs,
API keys, session secrets. They stay on the server and never reach the browser.

The one rule: **don't prefix a secret with `NEXT_PUBLIC_`.** That prefix is what
tells Next.js to compile the value into the JavaScript everyone downloads. The
script warns if it sees a `NEXT_PUBLIC_` name containing `SECRET`, `PASSWORD`,
`PRIVATE`, `_KEY` or `TOKEN`:

```
  ! A NEXT_PUBLIC_* name looks secret — those are compiled into the browser
  ! bundle and readable by anyone. Drop the NEXT_PUBLIC_ prefix to keep it server-side.
```

On the server the file is stored `chmod 600`, and the runtime copy
(`/var/www/<site>/.env.export`) is too.

---

## One file per environment

```
.env.production    DATABASE_URL=postgres://…/prod
.env.develop       DATABASE_URL=postgres://…/dev
```

Naming is `.env.<environment name>` — auto-detected. Editing `.env.develop`
cannot affect production.

If an environment has no file of its own it falls back to a shared `.env` and
warns. For a Next.js app that's worse than for a static site: production and
develop would share a **database URL**.

If the file doesn't exist yet, the script offers to seed it from your app's
`.env`.

---

## Malformed lines

Anything that isn't `KEY=value`, a comment, or blank is flagged — it would be
silently ignored otherwise:

```
  ! These lines are not KEY=value and will be ignored:
      12: DATABASE_URL postgres://localhost/app
```

Values may contain spaces and characters like `&` unquoted; that's valid dotenv
and handled correctly. The deploy never `source`s the file — it parses it — and
writes a shell-quoted copy for pm2 to read.

---

## Choosing a different editor

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
