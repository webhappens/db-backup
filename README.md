# db-backup

Stream MySQL, MariaDB and PostgreSQL backups straight to object storage with
[rclone](https://rclone.org), with no temporary files:

```
dump | gzip -c | rclone rcat <remote>/<timestamp>/<database>.sql.gz
```

It uses the same dump flags as Laravel Forge's own backups, adds flat or
tiered (hourly/daily/monthly) retention and an optional secondary copy, and
can ping a URL with the outcome of every run.

## Install

On the server (Ubuntu, Debian or RHEL-family Linux, amd64 or arm64):

```bash
curl -fsSL https://raw.githubusercontent.com/webhappens/db-backup/main/install.sh | sudo bash
```

This installs the latest release to `/usr/local/bin/db-backup`. If rclone is
missing or too old, it also installs a current rclone from rclone.org (as a
`.deb` or `.rpm` where the system uses one), checked against rclone's
published checksums. Pin a release with `sudo bash -s -- --version v1.0.0`.

Run the same command again to upgrade.

## Set up

As the user that will run the backups (e.g. `forge`):

1. Add an rclone remote for the bucket: `rclone config`
2. Write an env file only that user can read (`chmod 600 ~/db-backup.env`):

   ```bash
   DB_DRIVER=mysql            # mysql | mariadb | pgsql
   DB_USER=forge
   DB_PASSWORD=secret
   DB_NAMES=ALL               # or a space-separated list
   RCLONE_PRIMARY=hetzner:my-bucket/db-backups
   RETENTION_HOURLY=48
   RETENTION_DAILY=14
   RETENTION_MONTHLY=6
   PING_URL=https://hc-ping.com/<uuid>/{status}
   ```

3. Check it: `db-backup --env ~/db-backup.env --dry-run`
4. Schedule it, as a Forge scheduled job or in `/etc/cron.d/db-backup`:

   ```
   0 * * * * forge /usr/local/bin/db-backup --env /home/forge/db-backup.env --log /home/forge/db-backup.log
   ```

`db-backup --help` lists every option, including credential stores
(`--login-path`, `--service`) that keep the password out of the env file.

## Monitoring

With `--ping <url>` (or `PING_URL`), every run POSTs its outcome to the URL,
including runs that fail before any backup starts. `{status}` in the URL is
replaced with the exit code, which suits [healthchecks.io](https://healthchecks.io)
style checks: set the check's schedule to match the cron, and it also alerts
when a run never happens. The form fields are `status`, `host`, `timestamp`,
`started_at`, `finished_at`, `path` and `archives` (a JSON array with each
database's size, or the stage that failed).

A failed run never deletes older backups: retention is skipped, and a dump
that dies part-way has its truncated file removed.

## Restore

```bash
# MySQL / MariaDB
rclone cat hetzner:my-bucket/db-backups/20261113020000/myapp.sql.gz \
  | gunzip | mysql -u root -p myapp

# PostgreSQL: the dump drops and recreates the database, so connect to another
rclone cat hetzner:my-bucket/db-backups/20261113020000/myapp.sql.gz \
  | gunzip | psql -U postgres -d postgres -v ON_ERROR_STOP=1
```

A complete dump ends with `-- Dump completed on ...` (MySQL/MariaDB) or
`-- PostgreSQL database dump complete`, so `rclone cat ... | gunzip | tail -n1`
checks a backup without restoring it.

## Releasing

1. Update `VERSION` in `db-backup` and commit.
2. Tag and release: `gh release create v1.2.3 --generate-notes`

CI checks both scripts with shellcheck, and that a release tag matches
`VERSION`. The installer installs the latest GitHub release.
