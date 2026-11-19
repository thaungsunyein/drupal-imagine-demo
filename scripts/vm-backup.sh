#!/usr/bin/env bash
# Back up the Drupal database and files to Azure Blob Storage. Runs ON THE VM.
#
# Not run by hand from your machine: scripts/backup.sh sends it over ssh (with a short-lived SAS),
# and scripts/install-backup-timer.sh installs it as /usr/local/sbin/imagine-backup for the daily
# systemd timer, which authenticates with the VM's managed identity instead (no stored secret).
#
# Environment:
#   CONTAINER_URL  https://<account>.blob.core.windows.net/backups (default: /etc/imagine/backup.env)
#   SAS            optional SAS token; without it azcopy logs in with the VM's managed identity
#   TS             backup name, default: current UTC time (YYYYMMDDTHHMMSSZ)
#   APP_DIR        default /srv/drupal-imagine-demo;  KEEP_LOCAL  local copies to keep, default 3
#
# Writes /srv/backups/<TS>/{db.sql.gz,files.tar.gz,git-commit.txt} and uploads them to <TS>/.
set -euo pipefail

if [ -z "${CONTAINER_URL:-}" ] && [ -r /etc/imagine/backup.env ]; then
  # shellcheck disable=SC1091
  . /etc/imagine/backup.env
fi
: "${CONTAINER_URL:?CONTAINER_URL not set (and no /etc/imagine/backup.env)}"
APP_DIR="${APP_DIR:-/srv/drupal-imagine-demo}"
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
KEEP_LOCAL="${KEEP_LOCAL:-3}"

# One backup at a time (the timer and a manual run could overlap).
exec 9>/tmp/imagine-backup.lock
flock -n 9 || { echo "another backup is running" >&2; exit 1; }

cd "$APP_DIR"
dc() { docker compose -f docker-compose.yml -f docker-compose.prod.yml "$@"; }
dir="/srv/backups/$TS"
mkdir -p "$dir"
echo "Dumping database"
dc exec -T php drush sql-dump --structure-tables-key=common --gzip --result-file="/tmp/db-$TS.sql" </dev/null
dc cp "php:/tmp/db-$TS.sql.gz" "$dir/db.sql.gz"
dc exec -T php rm -f "/tmp/db-$TS.sql.gz" </dev/null
echo "Archiving files"
dc exec -T php tar -czf - -C web/sites/default/files \
  --exclude=./css --exclude=./js --exclude=./php . </dev/null > "$dir/files.tar.gz"
git rev-parse HEAD > "$dir/git-commit.txt"
gunzip -t "$dir/db.sql.gz"
ls -lh "$dir"

export AZCOPY_LOG_LOCATION=/tmp/azcopy AZCOPY_JOB_PLAN_LOCATION=/tmp/azcopy
if [ -n "${SAS:-}" ]; then
  dest="$CONTAINER_URL/$TS/?$SAS"
else
  export AZCOPY_AUTO_LOGIN_TYPE=MSI
  dest="$CONTAINER_URL/$TS/"
fi
echo "Uploading to $CONTAINER_URL/$TS/"
azcopy copy "$dir/*" "$dest" --log-level=ERROR --output-level=essential

find /srv/backups -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n -"$KEEP_LOCAL" | xargs -r rm -rf
echo "Backup done: $TS"
