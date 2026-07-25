# Setup — from nothing to a live HTTPS site

Do this **once per project**. Afterwards you only ever need [UPDATE.md](UPDATE.md).

---

## Before you start

| Need | Detail |
|---|---|
| Git Bash | This is a bash script. It will **not** run in PowerShell or CMD. |
| `.pem` key | The SSH key for the server, e.g. `testing.pem` in the parent folder. |
| Server IP | `54.89.160.254`, with passwordless `sudo` for the `ubuntu` user. |
| Repo URL | `https://github.com/you/repo.git` |
| GitHub token | Only for a private repo. A PAT with **Contents: Read**. |
| A domain | One per environment. See [DNS](#step-1--dns) below. |

Open Git Bash — in VS Code, the terminal dropdown (`∨` next to `+`) → **Git Bash**.

```bash
cd /c/Users/suraj/Downloads/vps/react
```

---

## Step 1 — DNS

Point every domain you plan to use at the server. Same IP for all of them:

```
surajsinghweather.surajsingh.online          A   54.89.160.254
develop-surajsinghweather.surajsingh.online  A   54.89.160.254
```

Rules that matter:

- **A bare hostname.** Not `http://…`, no trailing `/`. The script strips these
  for you, but get it right and there's nothing to strip.
- **No underscores.** `develop_site.example.com` is not a valid hostname and DNS
  will never resolve it. Use a hyphen.
- **Don't reuse a domain** already serving another site on this box.
- **Don't leave the domain blank** when the server hosts more than one site.
  Blank means `server_name _`, which only works for nginx's *default* site —
  already taken by the ClinicCare backend — so a blank-domain site is
  unreachable.

DNS not ready? Carry on anyway. Setup completes over HTTP and skips the
certificate; run `./react-develop.sh ssl <env>` once it propagates.

---

## Step 2 — Run setup

```bash
./react-develop.sh setup
```

Note the `./` — without it bash searches `$PATH`, which does not include the
current directory, and you get `command not found`.

### How many environments?

The first question. The industry-standard answer is **2**:

```
    1   production only          main -> your live domain
    2   + develop                develop -> its own domain
    3   + staging                staging -> its own domain
    4+  qa, uat, demo, preview, then env5, env6, ...
```

Environment 1 asks everything. Environments 2+ inherit the server, key, repo and
token, and only ask what genuinely differs — **name, branch, domain, env file**.

### Answering the questions

Every prompt shows a default in `[brackets]`. **Enter** accepts it.
**`-` clears a field back to empty** — the only way to undo a wrong answer,
since Enter keeps what's already there.

| Prompt | Notes |
|---|---|
| Path to `.pem` key | auto-detected if it's in this folder |
| Server IP, SSH user | `54.89.160.254`, `ubuntu` |
| Repo URL | HTTPS form, ending `.git` |
| Private repo? | `y` → asks username + token; typing is hidden |
| Branch | **verified against the repo immediately** — see below |
| Site name | drives `/var/www/<name>` and the nginx block. Make it descriptive: `myapp-develop`, not `develop` |
| Install command | leave as `npm ci` — **never** add `--omit=dev`, Vite and tsc are devDependencies |
| Build command | `npm run build` |
| Output dir | blank auto-detects `dist` → `build` → `out` |
| Env file | blank auto-detects `.env.<environment>` |
| Domain | bare hostname, or `-` for IP only |
| `/api/` proxy port | a number, or `-` for none |
| Let's Encrypt email | needed for HTTPS |
| UFW firewall | `y` |

### The branch check

Right after you enter a branch, the script asks the git host what actually
exists, using your token:

```
==> Verifying repo access and branch 'develop'
  ✓ Repo reachable — 2 branch(es) found
  ✓ Branch 'develop' exists
```

This catches three things before anything touches the server: a wrong repo URL,
an expired or under-scoped token, and a typo'd branch. If the branch is wrong it
lists the real ones and lets you pick again.

---

## Step 3 — Environment variables

Each environment gets its own file, next to the scripts:

```
.env.main        VITE_SITE_URL=https://surajsinghweather.surajsingh.online
.env.develop     VITE_SITE_URL=https://develop-surajsinghweather.surajsingh.online
```

Naming is `.env.<environment name>`. No config needed — auto-detected.

**This matters more than it looks.** Vite inlines `VITE_*` variables into the
JavaScript bundle **at build time**. If both environments share one `.env`, your
develop site ships production's URLs in its canonical tags and sitemap. If a
site falls back to a shared `.env`, the script warns:

```
  ! develop is using the shared .env — create .env.develop to give it its own values.
```

Two consequences worth internalising:

- **Changing a variable requires a rebuild**, not a restart. `./react-develop.sh env <name>`
  uploads and rebuilds for exactly this reason.
- **`VITE_*` values are public.** They are readable by anyone who opens the site.
  Never put a secret in one.

> If your repo **commits** its `.env`, the deploy handles it: the uploaded file
> is backed up before `git reset --hard` and restored after, since git would
> otherwise revert it to the committed version.

---

## Step 4 — Go live

```bash
./react-develop.sh setup all        # every environment
./react-develop.sh setup develop    # or one at a time
```

What happens, in order:

```
 1. SSH + passwordless sudo check      ← stops here if either fails,
                                          nothing on the server touched yet
 2. Check the stack                    ← installs ONLY what's missing;
                                          prints [present] for the rest
 3. Store git credentials              ← ~/.git-credentials, chmod 600
 4. Write the nginx server block
 5. Upload .env.<environment>
 6. Clone → npm ci → build             ← adds swap first if RAM < 2 GB
 7. Publish release + flip symlink     ← aborts if dist/ has no index.html,
                                          leaving the current site untouched
 8. Certbot + HTTP→HTTPS redirect      ← skipped if DNS isn't ready
```

Step 2 is a no-op on a server that already hosts a site:

```
[present] curl git ca-certificates gnupg build-essential ufw
[present] node v22.23.1 / npm 10.9.8
[present] nginx version: nginx/1.28.3 (Ubuntu)
[present] certbot 4.0.0
[present] ufw active, 22/80/443 already allowed
```

---

## Step 5 — Verify

```bash
./react-develop.sh status develop
```

Then in a browser:

- `https://<domain>` loads, `http://` redirects to it
- a deep link like `https://<domain>/some/route` returns the app, **not a 404**
  — nginx falls unknown paths through to `index.html` for client-side routing

---

## Adding another project later

A different app on the same server gets its own config file:

```bash
CONFIG_FILE=./portal.conf ./react-develop.sh setup
CONFIG_FILE=./portal.conf ./react-develop.sh deploy
```

Only the **site name** and **domain** must differ. React sites use no port, so
unlike Node backends there is nothing to allocate and nothing to collide.

---

## When something goes wrong

| Symptom | Cause |
|---|---|
| `command not found` | Missing `./`, or you're in PowerShell instead of Git Bash |
| `Permission denied` | `chmod +x react-develop.sh`, or run `bash react-develop.sh …` |
| `$'\r': command not found` | CRLF line endings — `dos2unix react-develop.sh` |
| `Several environments exist` | Name one: `./react-develop.sh status develop` |
| Branch "does NOT exist" | Real answer from the git host — pick from the list shown |
| certbot fails | DNS isn't pointing here yet. Fix the A record, run `ssl <env>` |
| Build killed with no error | Out of RAM. The script adds swap automatically; check disk space |

Full command list: `./react-develop.sh help`
