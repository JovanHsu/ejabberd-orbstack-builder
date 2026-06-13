#!/bin/sh
set -eu

export XMPP_DOMAIN="${XMPP_DOMAIN:-xmpp.pyramidtip.com}"
export EJABBERD_LOG_LEVEL="${EJABBERD_LOG_LEVEL:-warning}"
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export MESSAGE_FILTER_API_URL="${MESSAGE_FILTER_API_URL:-https://backend.pyramidtip.com/verify}"
export MESSAGE_FILTER_API_KEY="${MESSAGE_FILTER_API_KEY:-}"
export OFFLINE_PUSH_URL="${OFFLINE_PUSH_URL:-https://backend.pyramidtip.com/notify}"
export OFFLINE_PUSH_API_KEY="${OFFLINE_PUSH_API_KEY:-}"
export AUTH_MODE="${AUTH_MODE:-sql}"
export AUTH_PASSWORD_FORMAT="${AUTH_PASSWORD_FORMAT:-scram}"
export KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-https://kc.pyramidtip.com}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-cadoo}"
export KEYCLOAK_JWKS_URL="${KEYCLOAK_JWKS_URL:-${KEYCLOAK_BASE_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs}"
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-${KEYCLOAK_BASE_URL}/realms/${KEYCLOAK_REALM}}"
export KEYCLOAK_JID_FIELD="${KEYCLOAK_JID_FIELD:-preferred_username}"
export KEYCLOAK_JWKS_CACHE_TTL="${KEYCLOAK_JWKS_CACHE_TTL:-3600}"

case "$AUTH_MODE" in
  sql)
    AUTH_METHODS="  - sql"
    ;;
  keycloak|keycloak_sql|keycloak-custom|keycloak_custom)
    AUTH_METHODS="  - keycloak_custom
  - sql"
    # JWT token is supplied as the SASL PLAIN password. SCRAM cannot be used.
    AUTH_PASSWORD_FORMAT="plain"
    ;;
  *)
    echo "ERROR: unsupported AUTH_MODE=$AUTH_MODE (expected sql or keycloak)" >&2
    exit 64
    ;;
esac
export AUTH_METHODS AUTH_PASSWORD_FORMAT

required="POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD"
for name in $required; do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "ERROR: required env $name is empty" >&2
    exit 64
  fi
done

escape_sed_replacement() {
  # Escape characters that are special in the replacement side of sed s|||.
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

replace_var() {
  file="$1"
  name="$2"
  eval "value=\${$name:-}"
  escaped=$(escape_sed_replacement "$value")
  sed -i "s|\${$name}|$escaped|g" "$file"
}

render() {
  src="$1"
  dst="$2"
  if [ -f "$src" ]; then
    cp "$src" "$dst"
    for name in \
      XMPP_DOMAIN EJABBERD_LOG_LEVEL \
      POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
      REDIS_HOST REDIS_PORT REDIS_PASSWORD \
      MESSAGE_FILTER_API_URL MESSAGE_FILTER_API_KEY \
      OFFLINE_PUSH_URL OFFLINE_PUSH_API_KEY \
      AUTH_PASSWORD_FORMAT \
      KEYCLOAK_BASE_URL KEYCLOAK_REALM KEYCLOAK_JWKS_URL \
      KEYCLOAK_ISSUER KEYCLOAK_JID_FIELD KEYCLOAK_JWKS_CACHE_TTL; do
      replace_var "$dst" "$name"
    done
    # AUTH_METHODS is intentionally multiline YAML. sed replacement cannot
    # safely carry embedded newlines, so replace the whole placeholder line.
    if grep -q '^${AUTH_METHODS}$' "$dst"; then
      awk -v auth="$AUTH_METHODS" '{ if ($0 == "${AUTH_METHODS}") print auth; else print }' "$dst" > "$dst.tmp"
      mv "$dst.tmp" "$dst"
    fi
  fi
}

render /opt/ejabberd/conf/ejabberd.yml.template /opt/ejabberd/conf/ejabberd.yml
render /opt/ejabberd/.ejabberd-modules/mod_message_filter/conf/mod_message_filter.yml /tmp/mod_message_filter.yml
[ -f /tmp/mod_message_filter.yml ] && mv /tmp/mod_message_filter.yml /opt/ejabberd/.ejabberd-modules/mod_message_filter/conf/mod_message_filter.yml
render /opt/ejabberd/.ejabberd-modules/mod_offline_push/conf/mod_offline_push.yml /tmp/mod_offline_push.yml
[ -f /tmp/mod_offline_push.yml ] && mv /tmp/mod_offline_push.yml /opt/ejabberd/.ejabberd-modules/mod_offline_push/conf/mod_offline_push.yml

# Keep official image behaviour: run ejabberdctl in foreground by default.
exec /sbin/tini -- ejabberdctl "$@"
