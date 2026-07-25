# remove-env.sh — delete an environment

Removes an environment's config from your laptop and, if you say so, its site
from the server.

**This destroys things.** Read [What gets deleted](#what-gets-deleted) before
running it. There is a `--dry-run`.

```bash
cd /c/Users/suraj/Downloads/vps/react
./remove-env.sh --dry-run develop
```

---

## Commands

```bash
./remove-env.sh                     # menu — pick from a numbered list
./remove-env.sh develop             # straight to develop
./remove-env.sh 2                   # by number
./remove-env.sh --dry-run develop   # show what would go, delete NOTHING
./remove-env.sh --list              # show the table, change nothing
./remove-env.sh --help
```

Start with `--dry-run`. It prints the exact blast radius and exits.

---

## What gets deleted

```
On your laptop
  react-develop.<name>.conf              the environment's answers
  .env.<name>                            asked about separately

On the server
  /etc/nginx/sites-available/<site>      and its sites-enabled symlink
  /var/www/<site>                        EVERY release of the built site
  /home/ubuntu/apps/<site>               checkout + node_modules
  /var/log/nginx/<site>.*.log            that site's logs

Kept
  the TLS certificate for the domain
  every other site on this server
  the ClinicCare backend
```

The certificate is kept on purpose: it costs nothing to leave, and re-issuing
burns Let's Encrypt rate limit if you re-add the environment later.

---

## The confirmation

Three separate gates, because this isn't undoable:

**1. The full list, printed first.** Every path, before you're asked anything.

**2. Type the environment name.** Not `y` — the actual name:

```
  ! https://develop-surajsinghweather.surajsingh.online will stop working.

  Type the environment name (develop) to confirm: 
```

Anything else aborts with nothing deleted. A stray `y` can't destroy a site.

**3. The server is a separate question.**

```
  Also delete the site from the server? (y/N):
```

Defaults to **No**. Answer `N` and only the local config goes — the site keeps
serving. That's the right answer when you just want to stop managing an
environment from this laptop, or you're rebuilding a config from scratch.

`.env.<name>` is asked about separately again at the end, so you can keep your
variables while dropping the environment.

---

## Safety guards

Before any `rm -rf` runs on the server, the paths are validated:

| Variable | Must match | Rejects |
|---|---|---|
| `WEB_ROOT` | `/var/www/?*` | empty, `/`, bare `/var/www` |
| `APP_DIR` | `/home/?*` or `/root/?*` | empty, `/`, anything else |
| `APP_NAME` | non-empty | empty |

Any failure aborts before deleting. Without this, a config with an unset
`WEB_ROOT` would expand `rm -rf "$WEB_ROOT"` into `rm -rf ""` or worse — the
classic way a cleanup script destroys a server.

nginx is also only reloaded if `nginx -t` passes. If the remaining config is
broken for some other reason, the script says so and leaves nginx running on its
last good config rather than taking every site down.

---

## After removing

```
==> Still configured

  ENVIRONMENT    BRANCH       DOMAIN
  -----------    ------       ------
  main           main         surajsinghweather.surajsingh.online
```

You are warned first if you're deleting your **only** environment.

**The DNS record is yours to clean up.** The script doesn't touch DNS. Remove
the A record at your provider, or it keeps pointing at a server with nothing
there — visitors get whatever nginx's default site is.

---

## Re-adding later

```bash
./react-develop.sh setup <name>
```

It walks the wizard for a new environment. If you kept the certificate and the
DNS record, certbot reuses the existing cert instead of requesting a new one.

---

## When to use something else

| You want | Use |
|---|---|
| Undo a bad deploy | `./react-develop.sh rollback <name>` — instant, no rebuild |
| Change branch or domain | `./react-develop.sh config <name>` — no need to delete |
| Change variables | `./edit-env.sh <name>` |
| Just stop it serving | `--dry-run` first; or answer N to the server question and disable the nginx block by hand |

Removing and re-adding to change a setting is almost never the right move —
`config` edits any answer in place, with everything pre-filled.

---

## Related

- [EDIT-ENV.md](EDIT-ENV.md) — changing variables
- [UPDATE.md](UPDATE.md) — publishing code changes
- [SETUP.md](SETUP.md) — first-time setup
