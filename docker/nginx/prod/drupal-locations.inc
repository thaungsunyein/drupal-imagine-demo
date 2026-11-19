# Drupal front controller, shared by the production servers.
# Same lockdown as docker/nginx/default.conf (keep the two in step):
# only Drupal's own entry points execute PHP.
root /var/www/html/web;
index index.php;
client_max_body_size 64m;

location = /favicon.ico { log_not_found off; access_log off; }
location = /robots.txt  { allow all; log_not_found off; access_log off; }

# Never serve hidden files, logs, private files, or anything under vendor.
location ~ (^|/)\.            { return 403; }
location ~* \.(txt|log|yml|twig|sql)$ { deny all; }
location ~ ^/sites/.*/private/ { return 403; }
location ~ ^/sites/[^/]+/files/.*\.php$ { deny all; }

# Image styles are generated on first request by Drupal.
location ~ ^/sites/.*/files/styles/ { try_files $uri @rewrite; }
location ~ ^(/[a-z\-]+)?/system/files/ { try_files $uri /index.php?$query_string; }

# Only these PHP entry points run. (Cloudflare additionally blocks install/update publicly.)
location ~ '^/(index|update|core/install|core/authorize)\.php(/|$)' {
    fastcgi_split_path_info ^(.+?\.php)(|/.*)$;
    try_files $fastcgi_script_name =404;
    include fastcgi_params;
    fastcgi_param HTTP_PROXY "";
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_param PATH_INFO $fastcgi_path_info;
    fastcgi_param QUERY_STRING $query_string;
    fastcgi_intercept_errors on;
    fastcgi_read_timeout 120s;
    fastcgi_pass php:9000;
}
location ~ \.php(/|$) { return 404; }

# Static assets: long browser cache (Cloudflare caches at the edge too).
location ~* \.(js|css|png|jpe?g|gif|ico|svg|webp|mp3|woff2?)$ {
    try_files $uri @rewrite;
    expires 30d;
    log_not_found off;
}

location / { try_files $uri /index.php?$query_string; }
location @rewrite { rewrite ^ /index.php; }
