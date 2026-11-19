# Deploying cms.storyheroapp.com

One Azure VM runs the same Docker Compose stack as local development, plus
`docker-compose.prod.yml`. Cloudflare sits in front and handles DNS, edge TLS, WAF and caching.
Deploys run from your own machine over SSH. GitHub Actions only runs CI.

```
visitor ──https──▶ Cloudflare (Full strict) ──https, Origin CA cert──▶ VM :443 nginx ─▶ php-fpm ─▶ MariaDB
                                                                         └─ /srv/imagine-source (ro)
backups: VM ──azcopy + short-lived SAS──▶ Storage account / backups container
```

## What exists in Azure

Everything is defined in [`infra/main.bicep`](../infra/main.bicep) and lives in subscription
`0cb51b3b-7cba-43f1-9997-7c2cc91721da`, resource group `rg-imagine-demo`. The VM and its network are in **swedencentral**; the backups
storage is in **switzerlandnorth** (see [Why Sweden Central and D2als_v6](#why-sweden-central-and-d2als_v6)).

VM public IP: **20.240.50.42** (static).

| Resource | Name | Notes |
|---|---|---|
| VM | `vm-imagine-demo` | Standard_D2als_v6 (2 vCPU, 4 GB, AMD, NVMe disks), Ubuntu 24.04 LTS Gen2, Trusted Launch, SSH key only, user `azureuser` |
| OS disk | `osdisk-imagine-demo` | 30 GB StandardSSD_LRS |
| Data disk | `datadisk-imagine-demo-docker` | 32 GB StandardSSD_LRS, ext4, mounted at `/var/lib/docker` (images, containers, DB and files volumes) |
| Public IP | `pip-imagine-demo` | Standard, static |
| VNet / subnet | `vnet-imagine-demo` / `snet-default` | 10.40.0.0/16, 10.40.1.0/24 |
| NSG | `nsg-imagine-demo` | `Allow-SSH-Admin` (22 from one IP), `Allow-HTTP-Web` (80), `Allow-HTTPS-Web` (443) |
| NIC | `nic-imagine-demo` | |
| Storage | `stimaginedemo<hash>` | StorageV2, Standard_LRS, Cool, TLS 1.2, no public blob access, **no shared keys** (Entra ID only), 7-day soft delete |
| Container | `backups` | private; lifecycle rule deletes blobs after 30 days |
| Role | Storage Blob Data Contributor | for the person deploying, so they can mint user-delegation SAS tokens |

[`infra/cloud-init.yaml`](../infra/cloud-init.yaml) runs on first boot. It formats and mounts the
data disk at `/var/lib/docker` before installing Docker Engine and the compose plugin from Docker's
apt repo, installs azcopy from Microsoft's repo, adds `azureuser` to the `docker` group, turns on
unattended-upgrades, and creates `/srv/drupal-imagine-demo`, `/srv/imagine-source`, `/srv/backups`
and `/etc/imagine/tls`.

Expected cost: about $75/month while on D2als_v6 (VM about $63, plus two SSD disks, static IP and a
few GB of Cool blobs). Switching to B2als_v2 brings it to about $40.

### Creating or updating it

```bash
az group create -n rg-imagine-demo -l switzerlandnorth
```

```bash
az deployment group what-if -g rg-imagine-demo -f infra/main.bicep -p infra/main.parameters.json \
  -p sshSourceIp="$(curl -s https://api.ipify.org)" sshPublicKey="$(cat ~/.ssh/imagine_demo.pub)" \
     backupOperatorPrincipalId="$(az ad signed-in-user show --query id -o tsv)"
```

Then run the same command with `az deployment group create` instead of `what-if`. Re-running it is
safe and also the way to change the SSH source IP when yours changes. The deployment outputs give
the public IP, the ssh command and the storage account name.

### Why Sweden Central and D2als_v6

On 2026-11-19 Azure would not give this subscription a budget VM in Switzerland North:

- **`SkuNotAvailable` (Capacity Restrictions):** Standard_B2s in every EU region tried (all zones).
- **`QuotaExceeded`:** the newer B-series v2 sizes (B2als_v2 and similar), because Basv2/Bsv2
  quota is 0. A quota increase to 2 vCPUs was refused automatically for both Switzerland North
  and Sweden Central ("high demand").

Standard_D2als_v6 had both capacity and quota in Sweden Central, so the VM runs there. The
storage was already in Switzerland North and stays there (`location` vs `vmLocation`
parameters), so backups cross regions.

**Downsizing later.** Once a support request for 2 vCPUs of Basv2 in Sweden Central is approved,
resize in place. The IP, disks and data are kept, with a few minutes of downtime:

```bash
az vm deallocate -g rg-imagine-demo -n vm-imagine-demo
```

```bash
az vm resize -g rg-imagine-demo -n vm-imagine-demo --size Standard_B2als_v2 && az vm start -g rg-imagine-demo -n vm-imagine-demo
```

Then set `vmSize` to `Standard_B2als_v2` in `infra/main.parameters.json`. B-series v2 uses SCSI
disks instead of NVMe, and the mount uses the filesystem UUID, so `/var/lib/docker` mounts either
way. Run `df -h /var/lib/docker` after the restart to confirm.

First boot takes 3-5 minutes. Check it with:

```bash
ssh -i ~/.ssh/imagine_demo azureuser@<ip> 'cloud-init status --wait; docker version && docker compose version && df -h /var/lib/docker'
```

## The VM

| Path | What |
|---|---|
| `/srv/drupal-imagine-demo` | git checkout of this repo (`main`) |
| `/srv/drupal-imagine-demo/.env` | production settings and secrets, mode 600, never in git |
| `/srv/imagine-source` | Imagine Alice content, mounted read-only into php |
| `/etc/imagine/tls/origin.pem`, `origin.key` | Cloudflare Origin CA cert and key (you place these) |
| `/srv/backups` | the last 3 local backups |

Every script in `scripts/` runs on your machine and finds the VM IP via `az`. Set `VM_HOST=<ip>`
to skip the lookup. Other overrides are listed in [`scripts/lib.sh`](../scripts/lib.sh).

## First deploy, in order

1. `scripts/init-env.sh` creates `.env` on the VM with new random secrets (already done).
2. `scripts/sync-source.sh` copies the three Alice books from `~/Developer/imagine/content`
   (already done; re-run it whenever the content changes).
3. Place the Origin CA cert (see [Cloudflare](#cloudflare-manual-steps) below). You can deploy
   before this. nginx then serves plain http on port 80 only, which is enough to check the site at
   `http://<ip>/`. Because `TRUSTED_HOSTS` only allows `cms.storyheroapp.com`, test it with
   `curl -H 'Host: cms.storyheroapp.com' http://<ip>/`.
4. `scripts/deploy.sh`. On the first run it clones the repo, builds, installs Drupal from
   `config/sync` (`drush site:install --existing-config`, random admin password) and imports the
   Imagine migrations.
5. Get an admin login link:
   ```bash
   ssh -i ~/.ssh/imagine_demo azureuser@<ip> 'cd /srv/drupal-imagine-demo && docker compose -f docker-compose.yml -f docker-compose.prod.yml exec php drush uli --uri=https://cms.storyheroapp.com'
   ```

## Deploying changes

```bash
scripts/deploy.sh                 # main
```

```bash
scripts/deploy.sh --branch some-branch --migrate
```

It does: `git fetch` + fast-forward, `docker compose ... up -d --build`, the root `chown` of the
files volume, `composer install --no-dev --optimize-autoloader`, `drush deploy` (updb, cim, cr,
deploy hooks), then restarts php-fpm. The restart is required because production opcache has
`validate_timestamps=0`, so PHP never re-reads changed files on its own.

To roll back, deploy an older commit: push a revert to `main` and deploy again. Restore a backup
only if data has to go back too.

## nginx in production

`docker-compose.prod.yml` publishes 80 and 443 and mounts `docker/nginx/prod/`. On start,
`docker/nginx/prod/40-imagine-tls.sh` picks the server blocks:

- **cert present** (`/etc/imagine/tls/origin.pem` and `origin.key`): `:443` with TLS 1.2/1.3 and
  HTTP/2, and `:80` redirects to https.
- **no cert**: `:80` serves the site over plain http, and 443 is not listening.

Both use `drupal-locations.inc`, the same PHP entry-point lockdown as `docker/nginx/default.conf`.
`cloudflare-realip.conf` takes the visitor IP from `CF-Connecting-IP`, but only for requests from
Cloudflare's ranges. After adding or replacing the cert, run:

```bash
ssh -i ~/.ssh/imagine_demo azureuser@<ip> 'cd /srv/drupal-imagine-demo && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart nginx && docker compose -f docker-compose.yml -f docker-compose.prod.yml logs --tail=5 nginx'
```

The log line `imagine: Origin CA cert found` confirms https is on.

## Backups and restores

```bash
scripts/backup.sh
```

On your machine it mints a 60-minute, create/write-only user-delegation SAS (`az storage container
generate-sas --as-user --auth-mode login`, no account keys, since shared-key access is disabled on
the account). The SAS goes to the VM over ssh stdin. It is never written to the repo or the
command line. The VM then runs `drush sql-dump --gzip`, tars the files volume (without the
regenerated css/js/php caches), and uploads `db.sql.gz`, `files.tar.gz` and `git-commit.txt` to
`backups/<UTC timestamp>/` with azcopy.

```bash
scripts/restore.sh --list
```

```bash
scripts/restore.sh 20261119T210000Z     # or: latest
```

Restore asks you to type `restore`, or pass `--yes`. It downloads the backup with a read/list SAS,
drops and re-imports the database, replaces the files, fixes ownership and rebuilds caches. Code
is not rolled back. If the schema changed since the backup, first deploy the commit in
`git-commit.txt`.

There is no automatic schedule yet. Run a backup before every deploy that changes data, or add a
cron job on your machine.

## Rotating secrets

Secrets live only in `/srv/drupal-imagine-demo/.env` on the VM.

- **HASH_SALT**: replace the value in `.env`, then `scripts/deploy.sh`. All sessions and one-time
  links become invalid.
- **DB_PASSWORD** (the `drupal` user): MariaDB keeps the password it was created with, so change
  both sides:
  ```bash
  ssh -i ~/.ssh/imagine_demo azureuser@<ip>
  cd /srv/drupal-imagine-demo
  NEW=$(openssl rand -hex 24)
  ROOT=$(grep '^DB_ROOT_PASSWORD=' .env | cut -d= -f2-)
  docker compose exec -T db mariadb -uroot -p"$ROOT" -e "ALTER USER 'drupal'@'%' IDENTIFIED BY '$NEW';"
  sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$NEW/" .env
  unset NEW ROOT
  docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d php
  ```
- **DB_ROOT_PASSWORD**: same idea with `ALTER USER 'root'@'%'` and `'root'@'localhost'`, then update
  `.env` and `up -d db`. Drupal doesn't use it.
- **Drupal admin password**: `drush user:password admin "<new>"`, or just use `drush uli`.
- **SSH key**: add the new public key to `~azureuser/.ssh/authorized_keys`, test it, remove the old
  one, and pass the new key as `sshPublicKey` on the next Bicep deployment.
- **SAS tokens**: nothing to rotate. Each one expires after 60 minutes. To cut access right away,
  run `az storage account revoke-delegation-keys -g rg-imagine-demo -n <storage account>`.
- **Origin CA cert**: create a new one in Cloudflare, replace both files, restart nginx.

Only on a brand-new VM, with no `db` volume yet, can `scripts/init-env.sh --force` regenerate
everything in one go.

## Cloudflare manual steps

These need the Cloudflare dashboard for `storyheroapp.com`, so Tom does them by hand.

1. **DNS**: add an `A` record: name `cms`, IPv4 `<VM public IP>`, Proxy status **Proxied** (orange cloud).
2. **SSL/TLS > Overview**: set the encryption mode to **Full (strict)**. Under Edge Certificates,
   turn on Always Use HTTPS.
3. **SSL/TLS > Origin Server > Create Certificate**: RSA 2048, hostnames `cms.storyheroapp.com`
   (and `*.storyheroapp.com` if you like), 15 years, PEM. Put it on the VM:
   ```bash
   ssh -i ~/.ssh/imagine_demo azureuser@<ip> 'sudo tee /etc/imagine/tls/origin.pem >/dev/null' < origin.pem
   ```
   ```bash
   ssh -i ~/.ssh/imagine_demo azureuser@<ip> 'sudo tee /etc/imagine/tls/origin.key >/dev/null && sudo chmod 640 /etc/imagine/tls/origin.key && sudo chown root:azureuser /etc/imagine/tls/*' < origin.key
   ```
   Then restart nginx (see [nginx in production](#nginx-in-production)) and delete the local key file.
4. **Security > WAF > Custom rules**: add a rule named `Block Drupal install and update`.
   Expression:
   `(http.host eq "cms.storyheroapp.com" and (http.request.uri.path eq "/core/install.php" or http.request.uri.path eq "/update.php"))`,
   action **Block**. Run `drush updb` over SSH instead of using `/update.php`.
5. **Security > WAF > Rate limiting rules**: add a rule named `Login rate limit` with expression
   `(http.host eq "cms.storyheroapp.com" and http.request.uri.path eq "/user/login" and http.request.method eq "POST")`,
   5 requests per 10 seconds per IP, action **Block** for 10 seconds. The Free plan only offers the
   10-second period.
6. **Tighten the NSG** once the site works through Cloudflare, so only Cloudflare can reach 80/443:
   ```bash
   CF_V4=$(curl -fsS https://www.cloudflare.com/ips-v4 | tr '\n' ' ')
   ```
   ```bash
   az network nsg rule update -g rg-imagine-demo --nsg-name nsg-imagine-demo -n Allow-HTTP-Web --source-address-prefixes $CF_V4
   ```
   ```bash
   az network nsg rule update -g rg-imagine-demo --nsg-name nsg-imagine-demo -n Allow-HTTPS-Web --source-address-prefixes $CF_V4
   ```
   `$CF_V4` is unquoted on purpose, so each range becomes its own argument. The VM has IPv4 only,
   so the IPv6 ranges aren't needed. The current IPv4 list, as of 2026-11-19:
   `173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22`.
   After this, `http://<ip>/` stops answering from your own network. That is expected.
   Cloudflare changes these ranges rarely. When it does, re-run the two commands and update
   `docker/nginx/prod/cloudflare-realip.conf`.

   Note: re-running the Bicep deployment resets these two rules to `Internet`. Re-apply the
   commands afterwards, or make the source prefixes a Bicep parameter first.

## Changing the SSH source IP

When your IP changes:

```bash
az network nsg rule update -g rg-imagine-demo --nsg-name nsg-imagine-demo -n Allow-SSH-Admin --source-address-prefixes "$(curl -s https://api.ipify.org)/32"
```
