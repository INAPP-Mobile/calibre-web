# Calibre-Web v0.6.27 wrapper for Railway (one-click template).
#
# Upstream: janeczku/calibre-web, GPL-3.0. Calibre-Web is a web app for
# browsing, reading and downloading eBooks stored in a Calibre database
# (metadata.db) — book grid, search, OPDS feed, Kobo sync, upload and
# on-device reading. Single Python/Flask service, SQLite app database
# (app.db); no companion database service needed.
#
# Pin: linuxserver/calibre-web 0.6.27 (released 2026-08-08; image rebuilt
# 2026-11-22). amd64 manifest sha256:cbec28e41282dbf89f390e0bba56b8744f00e
# bcb05e365d15a1b605a7a35fd3b (manifest list
# sha256:18b65a754ec18f119af36ad672b5f1e64543c89648febd6df6edf64f5ec4c5b8).
# Digest-only FROM (no tag) — Railpack 0.43.0 fails to detect a Dockerfile
# whose FROM carries both a tag and a digest (proven 2026-11-05, TimeTagger).
#
# What the wrapper adds over the stock LSIO image:
# - PORT is honored: Calibre-Web reads CALIBRE_PORT at import
#   (cps/constants.py) and the entrypoint exports it from Railway's
#   injected $PORT, then also forces the stored config_port in app.db
#   to $PORT on every boot (the stored value wins over the env var
#   after first boot).
# - No setup wizard: the app refuses a library folder without a valid
#   metadata.db (cps/db.py setup_db returns None; the basic-config
#   save rejects "DB Location is not Valid"). The entrypoint seeds
#   upstream's own empty library/metadata.db (library/ in the source
#   repo, 0 books) into /books on first boot, and writes
#   config_calibre_dir=/books into app.db, so the app boots straight
#   to the login page.
# - Admin password is set once per volume: cps.py -s admin:<password>
#   (cps/ub.py password_change) creates app.db if missing, sets the
#   password, and exits. Guarded by a marker file so a deployer-changed
#   password survives redeploys. The password comes from the deploy
#   form as a generated secret (CW_ADMIN_PASSWORD) — never the
#   default admin/admin123.
# - Single Railway volume at /data: LSIO expects /config (app.db) and
#   a separate library dir; the entrypoint symlinks /config ->
#   /data/config and /books -> /data/books. LSIO's own init chowns
#   /config to abc:abc, and the entrypoint chowns the volume dirs and
#   the seeded metadata.db to abc:abc (the app runs as abc, uid 911)
#   so the root-owned Railway volume mount works.
#
# First run: open the public URL and log in as admin with the generated
# CW_ADMIN_PASSWORD from the deploy form. Upload an EPUB to see it in
# the library. Healthcheck is /login (unauthenticated 200).
FROM linuxserver/calibre-web@sha256:cbec28e41282dbf89f390e0bba56b8744f00ebcb05e365d15a1b605a7a35fd3b

USER root

COPY entrypoint.sh /entrypoint.sh
COPY seed/metadata.db /seed/metadata.db
RUN chmod +x /entrypoint.sh

LABEL org.opencontainers.image.source="https://github.com/INAPP-Mobile/calibre-web"

# LSIO ENTRYPOINT is /init (s6). entrypoint.sh runs the Railway
# first-boot setup above, then execs /init. Do NOT set CMD here:
# Docker runs ENTRYPOINT + CMD, so CMD ["/entrypoint.sh"] would pass
# the script path to /init as an argument (proven 2026-11-22, Komga).
EXPOSE 8083
ENTRYPOINT ["/entrypoint.sh"]
