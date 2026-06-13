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

required="POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD"
for name in $required; do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "ERROR: required env $name is empty" >&2
    exit 64
  fi
done

render() {
  src="$1"
  dst="$2"
  if [ -f "$src" ]; then
    envsubst '${XMPP_DOMAIN} ${EJABBERD_LOG_LEVEL} ${POSTGRES_HOST} ${POSTGRES_PORT} ${POSTGRES_DB} ${POSTGRES_USER} ${POSTGRES_PASSWORD} ${REDIS_HOST} ${REDIS_PORT} ${REDIS_PASSWORD} ${MESSAGE_FILTER_API_URL} ${MESSAGE_FILTER_API_KEY} ${OFFLINE_PUSH_URL} ${OFFLINE_PUSH_API_KEY}' < "$src" > "$dst"
  fi
}

render /opt/ejabberd/conf/ejabberd.yml.template /opt/ejabberd/conf/ejabberd.yml
render /opt/ejabberd/.ejabberd-modules/mod_message_filter/conf/mod_message_filter.yml /tmp/mod_message_filter.yml
[ -f /tmp/mod_message_filter.yml ] && mv /tmp/mod_message_filter.yml /opt/ejabberd/.ejabberd-modules/mod_message_filter/conf/mod_message_filter.yml
render /opt/ejabberd/.ejabberd-modules/mod_offline_push/conf/mod_offline_push.yml /tmp/mod_offline_push.yml
[ -f /tmp/mod_offline_push.yml ] && mv /tmp/mod_offline_push.yml /opt/ejabberd/.ejabberd-modules/mod_offline_push/conf/mod_offline_push.yml

# Keep official image behaviour: run ejabberdctl in foreground by default.
exec /sbin/tini -- ejabberdctl "$@"
