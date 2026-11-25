#!/bin/sh
# Calibre-Web wrapper entrypoint for Railway.
#
# Runs as root before LSIO's /init (s6). Sets up the single Railway
# volume, seeds an empty Calibre library, points the app at it, sets
# the admin password once per volume, then hands off to /init.
#
# - CALIBRE_PORT comes from Railway's injected $PORT (the app reads it
#   at import; the stored config_port is also forced to $PORT below,
#   because the stored value wins over the env var after first boot).
# - CALIBRE_DBPATH=/config makes the app use /config/app.db as its
#   settings database (cps/constants.py: CONFIG_DIR from CALIBRE_DBPATH).
# - The app will not create a Calibre library itself, so an empty
#   upstream metadata.db is seeded into /books on first boot.
# - Session protection is forced to 'basic' (config_session=0): Railway's
#   edge presents a different internal IP per connection and Calibre-Web
#   does not translate X-Forwarded-For, so Flask-Login 'strong' would
#   log the user out on every new connection.
set -eu

# Railway injects PORT; default to the app's 8083 when run outside Railway.
export CALIBRE_PORT="${PORT:-8083}"
export CALIBRE_DBPATH=/config

DATA_DIR=/data
CONFIG_DIR=/data/config
BOOKS_DIR=/data/books
SEED_DB=/seed/metadata.db
# Upstream's empty-library UUID (library/metadata.db, 0 books).
SEED_LIBRARY_UUID="60110156-93b0-4c79-8763-d6fc0ab596c4"

mkdir -p "$CONFIG_DIR" "$BOOKS_DIR"

# Single Railway volume at /data; LSIO expects /config and a separate
# library dir. Symlink both onto the volume (idempotent; a non-empty
# real directory is left alone so an existing install is never broken).
link_dir() {
  # $1 = link path, $2 = target dir
  if [ -L "$1" ]; then
    return 0
  fi
  if [ -d "$1" ]; then
    if [ -z "$(ls -A "$1")" ]; then
      rmdir "$1"
      ln -s "$2" "$1"
    fi
  else
    ln -s "$2" "$1"
  fi
}
link_dir /config "$CONFIG_DIR"
link_dir /books "$BOOKS_DIR"

# The app runs as abc (uid 911); Railway mounts volumes root-owned.
chown abc:abc "$CONFIG_DIR" "$BOOKS_DIR"

# Seed an empty Calibre library on first boot so the app never shows
# the setup wizard (it refuses a folder without a valid metadata.db).
if [ ! -f "$BOOKS_DIR/metadata.db" ]; then
  echo "Seeding empty Calibre library into $BOOKS_DIR..."
  cp "$SEED_DB" "$BOOKS_DIR/metadata.db"
  chown abc:abc "$BOOKS_DIR/metadata.db"
fi

# Create the settings database if it does not exist yet (cps.py -d is
# the updater dry-run; create_app builds app.db with the default admin
# and then exits). LSIO's own init does the same, but it runs after us.
if [ ! -f "$CONFIG_DIR/app.db" ]; then
  echo "First boot: creating app.db..."
  cd /app/calibre-web
  s6-setuidgid abc python3 /app/calibre-web/cps.py -d > /dev/null 2>&1 || true
fi

# Point the app at the seeded library and the Railway port, every boot.
# Each update is best-effort (a missing column must never kill the boot).
if [ -f "$CONFIG_DIR/app.db" ]; then
  sqlite3 "$CONFIG_DIR/app.db" \
    "UPDATE settings SET config_port=${CALIBRE_PORT};" \
    2>/dev/null || echo "warning: could not set config_port in app.db"
  sqlite3 "$CONFIG_DIR/app.db" \
    "UPDATE settings SET config_calibre_dir='/books' WHERE config_calibre_dir IS NULL OR config_calibre_dir='';" \
    2>/dev/null || echo "warning: could not set config_calibre_dir in app.db"
  sqlite3 "$CONFIG_DIR/app.db" \
    "UPDATE settings SET config_calibre_uuid='${SEED_LIBRARY_UUID}' WHERE config_calibre_uuid IS NULL OR config_calibre_uuid='';" \
    2>/dev/null || echo "warning: could not set config_calibre_uuid in app.db"
  # LSIO init sets this only on its own first-run path; set it here too
  # so KEPUB conversion finds the binary even when we created app.db.
  sqlite3 "$CONFIG_DIR/app.db" \
    "UPDATE settings SET config_kepubifypath='/usr/bin/kepubify' WHERE config_kepubifypath IS NULL OR LENGTH(config_kepubifypath)=0;" \
    2>/dev/null || echo "warning: could not set config_kepubifypath in app.db"
  # Railway's edge proxy presents a different internal IP per connection
  # and Calibre-Web's ReverseProxied never translates X-Forwarded-For
  # into REMOTE_ADDR, so request.remote_addr varies. Flask-Login 'strong'
  # session protection (config_session=1, the upstream default) hashes
  # remote_addr+User-Agent into the session and logs the user out
  # whenever it changes -- i.e. login succeeds but the very next request
  # on a new connection bounces back to /login. 'basic' (0) keeps the
  # user logged in and only marks the session non-fresh; Calibre-Web
  # never uses fresh_login_required, so nothing prompts for re-auth.
  sqlite3 "$CONFIG_DIR/app.db" \
    "UPDATE settings SET config_session=0;" \
    2>/dev/null || echo "warning: could not set config_session in app.db"
fi

# Set the admin password once per volume. cps.py -s creates app.db if
# missing, sets the password, and exits (cps/ub.py password_change).
# The marker keeps a deployer-changed password intact on redeploys.
if [ -n "${CW_ADMIN_PASSWORD:-}" ] && [ ! -f "$CONFIG_DIR/.railway-admin-seeded" ]; then
  echo "Setting admin password from CW_ADMIN_PASSWORD..."
  cd /app/calibre-web
  if s6-setuidgid abc python3 /app/calibre-web/cps.py -s "admin:${CW_ADMIN_PASSWORD}"; then
    touch "$CONFIG_DIR/.railway-admin-seeded"
    chown abc:abc "$CONFIG_DIR/.railway-admin-seeded" 2>/dev/null || true
    echo "Admin password set."
  else
    echo "warning: admin password seeding failed (will retry next boot)"
  fi
elif [ -z "${CW_ADMIN_PASSWORD:-}" ]; then
  echo "warning: CW_ADMIN_PASSWORD is not set; admin stays admin/admin123 until it is set and the service redeploys"
fi

# Hand off to LSIO's init (s6), which starts the app as abc.
exec /init
