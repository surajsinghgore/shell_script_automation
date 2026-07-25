# remove-env.sh — delete an environment

Removes an environment's config from your laptop and, if you say so, its
process and files from the server.

**This destroys things.** Read [What gets deleted](#what-gets-deleted) first.
There is a `--dry-run`.

```bash
cd /c/Users/suraj/Downloads/vps/next
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

---

## What gets deleted

```
On your laptop
  next-deploy.<name>.conf                the environment's answers
  .env.<name>                            asked about separately

On the server
  the pm2 process "<site>"               frees its port
  /etc/nginx/sites-available/<site>      and its sites-enabled symlink
  /var/www/<site>                        every release, start.sh, ecosystem,
                                         and .env.export
  /home/ubuntu/apps/<site>               checkout + node_modules
  /var/log/nginx/<site>.*.log

Kept
  the TLS certificate for the domain
  every other site and process on this server
```

Removing a Next.js environment frees noticeably more than a static one — the
process's RAM, its port, and typically 600 MB – 1 GB of disk.

---

## Order matters

The pm2 process is stopped **first**, before any files are deleted. Delete the
files out from under a running process and pm2 sees `server.js` disappear, tries
to restart, fails, and enters a crash loop — filling the logs with errors about
a site you meant to remove.

nginx is then reloaded **only if `nginx -t` passes**. If the remaining config is
broken for some other reason, the script says so and leaves nginx on its last
good config rather than taking every site down.

---

## The confirmation

Three gates, because this isn't undoable:

**1. The full list, printed first** — every path and the pm2 process, before
you're asked anything.

**2. Type the environment name.** Not `y` — the actual name:

```
  ! https://dev.example.com will stop working.

  Type the environment name (develop) to confirm: 
```

Anything else aborts with nothing deleted.

**3. The server is a separate question**, defaulting to **No**:

```
  Also delete the site from the server? (y/N):
```

Answer `N` and only the local config goes — the process keeps running and the
site keeps serving. That's right when you just want to stop managing it from
this laptop.

`.env.<name>` is asked about separately at the end.

---

## Safety guards

Before any `rm -rf` runs on the server:

| Variable | Must match | Rejects |
|---|---|---|
| `WEB_ROOT` | `/var/www/?*` | empty, `/`, bare `/var/www` |
| `APP_DIR` | `/home/?*` or `/root/?*` | empty, `/`, anything else |
| `APP_NAME` | non-empty | empty |

Any failure aborts before deleting. Without this, a config with an unset
`WEB_ROOT` turns `rm -rf "$WEB_ROOT"` into something catastrophic.

---

## After removing

```
==> Still configured

  ENVIRONMENT    BRANCH       PORT    DOMAIN
  -----------    ------       ----    ------
  production     main         3000    example.com
```

You're warned first if it's your **only** environment.

**The DNS record is yours to clean up** — the script doesn't touch DNS. Remove
the A record, or it keeps pointing at a server that no longer answers for it.

**The port is now free** and can be reused by a new environment.

---

## Re-adding later

```bash
./next-deploy.sh setup <name>
```

If you kept the certificate and the DNS record, certbot reuses the existing cert
instead of requesting a new one.

---

## When to use something else

| You want | Use |
|---|---|
| Undo a bad deploy | `./next-deploy.sh rollback <name>` — seconds, no rebuild |
| Change branch, domain or port | `./next-deploy.sh config <name>` |
| Change variables | `./edit-env.sh <name>` |
| Stop it temporarily | `pm2 stop <site>` on the server — keeps everything |

Removing and re-adding to change a setting is almost never right — `config`
edits any answer in place, pre-filled.

---

## Related

- [EDIT-ENV.md](EDIT-ENV.md) — changing variables
- [UPDATE.md](UPDATE.md) — publishing code changes
- [SETUP.md](SETUP.md) — first-time setup
