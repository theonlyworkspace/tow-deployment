#!/bin/sh
set -eu

PUBLIC_HOST="${PUBLIC_HOST:-localhost}"
TLS_MODE="${TLS_MODE:-off}"
PROXY_CLIENT_MAX_BODY_SIZE="${PROXY_CLIENT_MAX_BODY_SIZE:-25m}"
AUTHENTIK_PATH_ENABLED="${AUTHENTIK_PATH_ENABLED:-false}"
AUTHENTIK_PATH="${AUTHENTIK_PATH:-/authentik/}"
AUTHENTIK_UPSTREAM="${AUTHENTIK_UPSTREAM:-http://authentik-server:9000}"
TLS_CERT_PATH="${TLS_CERT_PATH:-/etc/nginx/certs/fullchain.pem}"
TLS_KEY_PATH="${TLS_KEY_PATH:-/etc/nginx/certs/privkey.pem}"

case "$AUTHENTIK_PATH" in
  /*) ;;
  *) AUTHENTIK_PATH="/$AUTHENTIK_PATH" ;;
esac
case "$AUTHENTIK_PATH" in
  */) ;;
  *) AUTHENTIK_PATH="$AUTHENTIK_PATH/" ;;
esac
AUTHENTIK_PATH_NOSLASH="${AUTHENTIK_PATH%/}"

export PUBLIC_HOST
export TLS_CERT_PATH
export TLS_KEY_PATH
export PROXY_CLIENT_MAX_BODY_SIZE
export AUTHENTIK_PATH
export AUTHENTIK_PATH_NOSLASH
export AUTHENTIK_UPSTREAM

render_vars='${PUBLIC_HOST} ${TLS_CERT_PATH} ${TLS_KEY_PATH} ${PROXY_CLIENT_MAX_BODY_SIZE} ${AUTHENTIK_PATH} ${AUTHENTIK_PATH_NOSLASH} ${AUTHENTIK_UPSTREAM}'
rendered_dir=/tmp/tow-nginx-rendered
mkdir -p "$rendered_dir"
rm -f /etc/nginx/conf.d/default.conf

render() {
  envsubst "$render_vars" < "$1" > "$2"
}

case "$(printf '%s' "$AUTHENTIK_PATH_ENABLED" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)
    render /etc/nginx/launch/templates/authentik-location.conf.template "$rendered_dir/authentik-location.conf"
    ;;
  *)
    : > "$rendered_dir/authentik-location.conf"
    ;;
esac

render /etc/nginx/launch/templates/locations.conf.template "$rendered_dir/locations.conf"

case "$TLS_MODE" in
  off)
    render /etc/nginx/launch/templates/http.conf.template /etc/nginx/conf.d/tow.conf
    ;;
  provided)
    if [ -r "$TLS_CERT_PATH" ] && [ -r "$TLS_KEY_PATH" ]; then
      render /etc/nginx/launch/templates/provided.conf.template /etc/nginx/conf.d/tow.conf
    else
      echo "TLS_MODE=provided but TLS_CERT_PATH or TLS_KEY_PATH is not readable; starting proxy without TLS." >&2
      render /etc/nginx/launch/templates/http.conf.template /etc/nginx/conf.d/tow.conf
    fi
    ;;
  *)
    echo "Unsupported TLS_MODE: $TLS_MODE" >&2
    exit 2
    ;;
esac

if [ "$#" -eq 0 ]; then
  set -- nginx -g "daemon off;"
fi

exec "$@"
