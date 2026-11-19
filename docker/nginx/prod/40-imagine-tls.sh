#!/bin/sh
# Runs from the nginx image's /docker-entrypoint.d before nginx starts.
# Picks the production server blocks depending on whether the Origin CA cert is present,
# so nginx starts (http only) before the cert has been placed on the host.
set -eu
src=/etc/nginx/imagine
dst=/etc/nginx/conf.d
rm -f "$dst"/imagine-*.conf
cp "$src/cloudflare-realip.conf" "$dst/imagine-00-realip.conf"
if [ -s /etc/nginx/tls/origin.pem ] && [ -s /etc/nginx/tls/origin.key ]; then
    cp "$src/https.conf" "$dst/imagine-10-https.conf"
    cp "$src/http-redirect.conf" "$dst/imagine-20-http.conf"
    echo "imagine: Origin CA cert found, serving https on 443, redirecting 80"
else
    cp "$src/http-site.conf" "$dst/imagine-20-http.conf"
    echo "imagine: WARNING no cert at /etc/nginx/tls/origin.{pem,key}; serving plain http on 80 only"
fi
