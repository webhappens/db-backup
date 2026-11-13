#!/usr/bin/env bash
# install.sh -- install or upgrade db-backup, and rclone if needed, on Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/webhappens/db-backup/main/install.sh | sudo bash
#   curl -fsSL ... | sudo bash -s -- --version v1.0.0
#
# db-backup goes to /usr/local/bin. rclone is installed from rclone.org when
# it is missing or older than db-backup's MIN_RCLONE: as a .deb or .rpm where
# the system uses one, otherwise the plain binary in /usr/bin (on cron's
# default PATH, like the packages). A new enough rclone is left alone.
# Database dump tools are only checked, never installed: they need to match
# the database server's version.

set -euo pipefail

REPO=webhappens/db-backup
RAW_BASE="${DB_BACKUP_RAW_BASE:-https://raw.githubusercontent.com/$REPO}"
RCLONE_VERSION=1.76.0  # installed when rclone is missing or too old

VERSION=""  # db-backup release tag or git ref; empty = latest release

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# True when version $1 >= version $2.
version_gte() { [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

rclone_version() { rclone version 2>/dev/null | awk 'NR==1 {sub(/^v/, "", $2); print $2}'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || die "--version requires a value"
            VERSION="$2"; shift 2 ;;
        --help)
            log "Usage: install.sh [--version <tag>]   (default: latest release)"
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$(uname -s)" == Linux ]] \
    || die "install.sh supports Linux only (on macOS: brew install rclone, and put db-backup on your PATH)"
[[ "$EUID" -eq 0 ]] || die "Run as root, e.g. curl -fsSL <url> | sudo bash"
command -v curl >/dev/null 2>&1 || die "curl is required"

case "$(uname -m)" in
    x86_64)        ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *)             die "Unsupported architecture: $(uname -m)" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- db-backup ---------------------------------------------------------------
if [[ -z "$VERSION" ]]; then
    # github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>.
    latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" || true)"
    VERSION="${latest##*/}"
    [[ "$latest" == */releases/tag/* && -n "$VERSION" ]] \
        || die "Could not find the latest db-backup release (pass --version <tag>)"
fi

log "Downloading db-backup $VERSION"
curl -fsSL "$RAW_BASE/$VERSION/db-backup" -o "$TMP/db-backup" \
    || die "Could not download db-backup $VERSION"
if ! { grep -q "^VERSION=" "$TMP/db-backup" && bash -n "$TMP/db-backup"; }; then
    die "The downloaded db-backup is not a valid script"
fi

new_version="$(sed -n 's/^VERSION=//p' "$TMP/db-backup")"
min_rclone="$(sed -n 's/^MIN_RCLONE=//p' "$TMP/db-backup")"
old_version=""
if [[ -x /usr/local/bin/db-backup ]]; then
    old_version="$(/usr/local/bin/db-backup --version 2>/dev/null | awk '{print $2}' || true)"
fi

install -m 0755 "$TMP/db-backup" /usr/local/bin/db-backup
if [[ -n "$old_version" && "$old_version" != "$new_version" ]]; then
    log "Upgraded db-backup $old_version -> $new_version"
else
    log "Installed db-backup $new_version at /usr/local/bin/db-backup"
fi

# --- rclone ------------------------------------------------------------------
current=""
if command -v rclone >/dev/null 2>&1; then current="$(rclone_version)"; fi

if [[ -n "$current" ]] && version_gte "$current" "${min_rclone:-0}"; then
    log "rclone $current is already installed (db-backup needs $min_rclone or later)"
else
    if [[ -n "$current" ]]; then
        log "rclone $current is older than $min_rclone; installing rclone $RCLONE_VERSION"
    else
        log "Installing rclone $RCLONE_VERSION"
    fi

    if command -v dpkg >/dev/null 2>&1; then
        ext=deb
    elif command -v rpm >/dev/null 2>&1; then
        ext=rpm
    else
        ext=zip
        command -v unzip >/dev/null 2>&1 || die "unzip is required to install rclone on this system"
    fi

    base="https://downloads.rclone.org/v$RCLONE_VERSION"
    file="rclone-v$RCLONE_VERSION-linux-$ARCH.$ext"
    curl -fsSL "$base/$file" -o "$TMP/$file" || die "Could not download $base/$file"
    curl -fsSL "$base/SHA256SUMS" -o "$TMP/SHA256SUMS" || die "Could not download $base/SHA256SUMS"
    (cd "$TMP" && grep " $file\$" SHA256SUMS | sha256sum -c --quiet -) \
        || die "Checksum mismatch for $file"

    case "$ext" in
        deb) dpkg -i "$TMP/$file" >/dev/null ;;
        rpm) rpm -U --quiet "$TMP/$file" ;;
        zip)
            unzip -q "$TMP/$file" -d "$TMP"
            install -m 0755 "$TMP/${file%.zip}/rclone" /usr/bin/rclone
            ;;
    esac

    hash -r
    current="$(rclone_version)"
    version_gte "$current" "$min_rclone" \
        || die "rclone $current at $(command -v rclone) still comes first on PATH; remove it so the new one is used"
    log "Installed rclone $current at $(command -v rclone)"
fi

# --- Dump tools (checked only) -----------------------------------------------
found=""
for tool in mysqldump mariadb-dump pg_dump; do
    if command -v "$tool" >/dev/null 2>&1; then found+=" $tool"; fi
done
if [[ -n "$found" ]]; then
    log "Found dump tools:$found"
else
    warn "No mysqldump, mariadb-dump or pg_dump found; install the one matching your database server"
fi

cat <<'EOF'

Next steps, as the user that will run backups (e.g. forge):
  1. rclone config        # add a remote for the bucket
  2. Write an env file only that user can read (chmod 600), e.g.
     ~/db-backup.env -- see db-backup --help for the variables
  3. db-backup --env ~/db-backup.env --dry-run
  4. Schedule it, e.g. as a Forge scheduled job or in /etc/cron.d/db-backup:
     0 * * * * forge /usr/local/bin/db-backup --env /home/forge/db-backup.env --log /home/forge/db-backup.log --hourly 48 --daily 14 --monthly 6
EOF
