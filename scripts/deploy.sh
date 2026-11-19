#!/usr/bin/env bash
# Deploy the site to the Azure VM, from your own machine.
#
# Usage: scripts/deploy.sh [--branch NAME] [--migrate]
#   --branch NAME  git branch to deploy (default: main)
#   --migrate      also run `drush migrate:import --group=imagine` (always done on first install)
#
# On the VM, in /srv/drupal-imagine-demo: sets up the checkout on first run, otherwise fast-forwards
# to origin/<branch>; builds and starts the stack with docker-compose.prod.yml; fixes ownership
# of the files volume; composer install --no-dev; on the first run installs Drupal (standard +
# config/sync) and imports the migrations, otherwise `drush deploy`; restarts php-fpm (opcache does not re-check files in prod).
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
# First run: the folder already exists (cloud-init) and may hold .env (init-env.sh),
# so set up git in place instead of `git clone`. .env is git-ignored and stays put.
mkdir -p "$APP_DIR"
cd "$APP_DIR"
if [ ! -d .git ]; then
  git init -q
  git remote add origin "$REPO_URL"
  git fetch -q origin "$BRANCH"
  git checkout -q -b "$BRANCH" "origin/$BRANCH"
fi
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
  # `site:install --existing-config` refuses the standard profile (it has hook_install), so:
  # install standard, adopt the site UUID from config/sync, drop the default shortcuts that
  # would block the import, then import config.
  echo "No Drupal site yet: installing standard, then importing config/sync"
  dc exec -T php drush site:install standard -y \
    --account-name=admin --account-pass="$(openssl rand -base64 24)"
  dc exec -T php drush config:set -y system.site uuid "$(sed -n 's/^uuid: //p' config/sync/system.site.yml)"
  dc exec -T php drush entity:delete shortcut -y
  dc exec -T php drush config:import -y
  # A new site has no interface translations yet, and locale builds the FR/DE translations of
  # core config from them, so without this they go missing. Fetch them, then import again.
  dc exec -T php drush locale:check
  dc exec -T php drush locale:update
  dc exec -T php drush config:import -y
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
