#!/bin/sh
set -eu

trusted_proxy_cidrs="${OPENPAY_TRUSTED_PROXY_CIDRS:-127.0.0.1/32}"
proxy_directives=""
proxy_geo_directives=""

for cidr in ${trusted_proxy_cidrs}; do
    if ! printf '%s\n' "${cidr}" | awk -F'[./]' 'NF == 5 && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255 && $5 <= 32 && $1 >= 0 && $2 >= 0 && $3 >= 0 && $4 >= 0 && $5 >= 0 { valid = 1 } END { exit !valid }'; then
        echo "OPENPAY_TRUSTED_PROXY_CIDRS contains an invalid IPv4 CIDR" >&2
        exit 1
    fi
    proxy_directives="${proxy_directives}set_real_ip_from ${cidr};
"
    proxy_geo_directives="${proxy_geo_directives}    ${cidr} 1;
"
done

awk -v directives="${proxy_directives}" '{ sub(/__OPENPAY_TRUSTED_PROXY_DIRECTIVES__/, directives) } { print }' \
    /etc/nginx/openpay.conf.template > /etc/nginx/conf.d/default.conf

awk -v directives="${proxy_geo_directives}" '{ sub(/__OPENPAY_TRUSTED_PROXY_GEO_DIRECTIVES__/, directives) } { print }' \
    /etc/nginx/openpay-proxy-map.conf.template > /etc/nginx/conf.d/00-openpay-proxy-map.conf
