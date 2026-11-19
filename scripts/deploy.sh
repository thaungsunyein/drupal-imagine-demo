#!/usr/bin/env bash
# Deploy the site to the Azure VM, from your own machine.
#
# Usage: scripts/deploy.sh [--branch NAME] [--migrate]
#   --branch NAME  git branch to deploy (default: main)
#   --migrate      also run `drush migrate:import --group=imagine` (always done on first install)
#
# On the VM, in /srv/drupal-imagine-demo: clones the repo on first run, otherwise fast-forwards
# to origin/<branch>; builds and starts the stack with docker-compose.prod.yml; fixes ownership
# of the files volume; composer install --no-dev; installs Drupal from config/sync on the first
# run, otherwise `drush deploy`; restarts php-fpm (opcache does not re-check files in prod).
# Requires the production .env on the VM (scripts/init-env.sh). Env overrides: see scripts/lib.sh.
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

BRANCH=main
MIGRATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --migrate) MIGRATE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

need_vm
echo "Deploying $BRANCH to $VM_USER@$VM_HOST:$APP_DIR"
{ remote_vars APP_DIR REPO_URL BRANCH MIGRATE; cat <<'REMOTE'
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
if [ ! -d "$APP_DIR/.git" ]; then
  git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR"
[ -f .env ] || { echo "error: $APP_DIR/.env missing; run scripts/init-env.sh first" >&2; exit 1; }
git fetch --prune origin
git checkout "$BRANCH"
git merge --ff-only "origin/$BRANCH"
echo "At $(git log -1 --format='%h %s')"

dc() { docker compose -f docker-compose.yml -f docker-compose.prod.yml "$@"; }
dc up -d --build --remove-orphans
# The named files volume is created root-owned on first start.
dc exec -T -u root php chown www-data:www-data web/sites/default/files
dc exec -T php composer install --no-dev --optimize-autoloader --no-interaction --no-progress

if dc exec -T php drush status --field=bootstrap 2>/dev/null | grep -q Successful; then
  dc exec -T php drush deploy -y
else
  echo "No Drupal site yet: installing from config/sync"
  dc exec -T php drush site:install --existing-config -y \
    --account-name=admin --account-pass="$(openssl rand -base64 24)"
  MIGRATE=1
fi
if [ "$MIGRATE" = 1 ]; then
  dc exec -T php drush migrate:import --group=imagine
  dc exec -T php drush migrate:status --group=imagine
fi
# validate_timestamps=0: php-fpm only sees new code after a restart.
dc restart php
dc exec -T php drush cache:rebuild
dc ps
REMOTE
} | vm_script

echo "Done. One-time admin login link: ssh in and run"
echo "  cd $APP_DIR && docker compose -f docker-compose.yml -f docker-compose.prod.yml exec php drush uli --uri=https://cms.storyheroapp.com"
