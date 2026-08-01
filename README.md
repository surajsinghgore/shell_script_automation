# shell_script_automation

Deploy React, Next.js and Node apps to your own VPS with one command.

No CI service, no Docker, no Kubernetes. Bash over SSH — you can read every line
of what it does to your server.

---

## Which toolchain?

| Your app | Folder | Runs as | Docs |
|---|---|---|---|
| React, Vite, CRA — a static SPA | [`react/`](react/) | files on disk, nginx serves them | [react/README.md](react/README.md) |
| Next.js with SSR / API routes | [`next/`](next/) | `node server.js` under pm2 | [next/README.md](next/README.md) |
| Express, Nest, Fastify, any API | [`node/`](node/) | your start command under pm2 | [node/README.md](node/README.md) |

All three share the same four scripts and the same command surface, so learning
one teaches you the others:

```
<engine>.sh     setup, ssl, rollback, releases, logs, status, config, …
update.sh       the daily loop: pull, build, publish
edit-env.sh     change variables and apply them
remove-env.sh   delete an environment
```

Plus [`ops/`](ops/) — server-wide health checking, independent of any one app.

---

## Five minutes to live

```bash
cd react
```

```bash
./react-develop.sh setup
```

Answer the questions once — server, key, repo, branch, domain. Every deploy
after that is:

```bash
./update.sh
```

Full walkthrough in each folder's `SETUP.md`.

---

## What it does for you

**Atomic releases.** Each build lands in its own directory and a symlink is
flipped in one rename. Visitors never see a half-published site.

**Instant rollback**, because previous builds stay on disk:

```bash
./react-develop.sh rollback main
```

**It checks before it builds.** Nothing changed? It says so instead of burning
three minutes:

```bash
./update.sh --check
```

**Multiple environments** — production, develop, staging — each with its own
branch, domain, port and release history:

```bash
./update.sh develop
```

**Free HTTPS**, issued and renewed automatically.

**Guards that earned their place.** Every one of these exists because it caught
something real:

- refuses to build without enough disk, sized to measured figures per stack
- never destroys working swap to make room for more swap
- aborts if the build output is missing or incomplete
- verifies the branch exists before touching the server
- stops pm2 before deleting files, so it cannot crash-loop on a deleted binary
- validates every path before any `rm -rf`
- parses `.env` instead of `source`-ing it, so `KEY=Some Value` does not execute

---

## Environments and secrets

Each environment keeps two files beside its scripts:

```
<engine>.<env>.conf    server, key, repo, branch, domain, port
.env.<env>             the app's variables
```

Both are **gitignored** and `chmod 600`. They hold your git token and app
secrets, and never leave your laptop except over SSH.

Where secrets may live differs by stack, and it matters:

| | Safe to hold secrets? |
|---|---|
| `react/` `.env.*` | **No** — `VITE_*` is compiled into the browser bundle |
| `next/` `.env.*` | Only outside `NEXT_PUBLIC_*` |
| `node/` `.env.*` | **Yes** — nothing here reaches a browser |

---

## Keeping the server healthy

```bash
./ops/install-healthcheck.sh --run
```

Installs a cron job that every 15 minutes checks every site nginx serves, every
pm2 process, and disk usage, then logs and reports anything wrong. It discovers
sites from nginx's own config, so a site added tomorrow is checked tomorrow.

```bash
./ops/install-healthcheck.sh --tail
```

See [SERVER.md](SERVER.md) for what lives where on the box, and how to rebuild
it from nothing.

---

## Requirements

**Your laptop** — Git Bash on Windows, or any bash on macOS/Linux. `ssh`, `scp`,
`git`, `curl`. Nothing to install.

**Your server** — Ubuntu with an SSH key and passwordless `sudo`. Node, pm2,
nginx and certbot are installed for you if missing, and skipped if present.

**Sizing** — roughly what each environment costs:

| Stack | Disk | RAM |
|---|---|---|
| React SPA | ~120 MB | none (no process) |
| Node API | ~320 MB | ~150 MB |
| Next.js SSR | ~660 MB | ~250 MB |

An 8 GB / 1 GB box comfortably runs one Next.js app plus a couple of static
sites. Two Next.js environments will not fit — the scripts refuse up front
rather than filling the disk.

---

## Deploy automatically on push

Everything above is driven from your laptop. To have GitHub deploy for you
instead, see [CI.md](CI.md).

---

## Licence

Use it, change it, no warranty. It runs commands on your server via `sudo` —
read it before pointing it at anything you care about.
