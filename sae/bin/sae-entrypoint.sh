#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

consul_api() {
  method="$1"
  path="$2"
  data="${3:-}"
  url="${CONSUL_HTTP_ADDR%/}$path"
  args="-fsS --connect-timeout 3 --max-time 10"
  if [ -n "${CONSUL_HTTP_TOKEN:-}" ]; then
    args="$args -H X-Consul-Token:$CONSUL_HTTP_TOKEN"
  fi
  if [ "$method" = "GET" ]; then
    # shellcheck disable=SC2086
    curl $args "$url"
  else
    # shellcheck disable=SC2086
    curl $args -X "$method" --data-binary "$data" "$url"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

set_cfg_value() {
  key="$1"
  value="$2"
  if grep -q "^$key=" /opt/ejabberd/conf/ejabberdctl.cfg; then
    sed -i "s/^$key=.*/$key=$value/" /opt/ejabberd/conf/ejabberdctl.cfg
  else
    printf '\n%s=%s\n' "$key" "$value" >> /opt/ejabberd/conf/ejabberdctl.cfg
  fi
}

get_self_ip() {
  if [ -n "${SAE_INSTANCE_IP:-}" ]; then
    printf '%s' "$SAE_INSTANCE_IP"
  elif [ -n "${POD_IP:-}" ]; then
    printf '%s' "$POD_IP"
  else
    hostname -i | awk '{print $1}'
  fi
}

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

export CLUSTER_ENABLED="${CLUSTER_ENABLED:-false}"
export CLUSTER_DISCOVERY="${CLUSTER_DISCOVERY:-consul}"
export CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
export CONSUL_SERVICE_NAME="${CONSUL_SERVICE_NAME:-ejabberd-cluster}"
export CONSUL_KV_PREFIX="${CONSUL_KV_PREFIX:-service/ejabberd/cluster}"
export CONSUL_CHECK_TTL="${CONSUL_CHECK_TTL:-30s}"
export CONSUL_HEARTBEAT_INTERVAL="${CONSUL_HEARTBEAT_INTERVAL:-10}"
export CLUSTER_JOIN_RETRIES="${CLUSTER_JOIN_RETRIES:-30}"
export CLUSTER_JOIN_INTERVAL="${CLUSTER_JOIN_INTERVAL:-5}"
export CLUSTER_REQUIRE_JOIN="${CLUSTER_REQUIRE_JOIN:-true}"
export CLUSTER_READY_FILE="${CLUSTER_READY_FILE:-/tmp/ejabberd-ready}"
export CLUSTER_DIST_PORT="${CLUSTER_DIST_PORT:-${ERL_DIST_PORT:-4370}}"
# The upstream ejabberdctl treats ERL_DIST_PORT as "epmd replacement" and
# starts Erlang with -start_epmd false. For clustering we want the normal EPMD
# port 4369 plus a fixed Erlang distribution listen window. Keep the user-facing
# ERL_DIST_PORT alias for compatibility, but do not leak it to ejabberdctl.
unset ERL_DIST_PORT

if [ "$CLUSTER_ENABLED" = "true" ]; then
  if [ "$CLUSTER_DISCOVERY" != "consul" ]; then
    echo "ERROR: unsupported CLUSTER_DISCOVERY=$CLUSTER_DISCOVERY (expected consul)" >&2
    exit 64
  fi
  SELF_IP="$(get_self_ip)"
  ERLANG_NODE_VALUE="${ERLANG_NODE_ARG:-ejabberd@$SELF_IP}"
  export ERLANG_NODE_ARG="$ERLANG_NODE_VALUE"
  export FIREWALL_WINDOW="${FIREWALL_WINDOW:-$CLUSTER_DIST_PORT-$CLUSTER_DIST_PORT}"
  : "${ERLANG_COOKIE:?ERROR: ERLANG_COOKIE is required when CLUSTER_ENABLED=true}"
fi

if [ -n "${FIREWALL_WINDOW:-}" ]; then
  # The upstream ejabberdctl reads FIREWALL_WINDOW from ejabberdctl.cfg,
  # not from the process environment. Persist it before starting the release
  # so Erlang distribution listens on a predictable in-container port.
  set_cfg_value FIREWALL_WINDOW "$FIREWALL_WINDOW"
fi

# Do not write ERL_DIST_PORT to ejabberdctl.cfg here. In the upstream wrapper
# that variable changes EPMD behaviour. For cluster traffic we only need to
# constrain the Erlang distribution listen window to a fixed in-container port.

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

consul_register_service() {
  service_id="$(printf '%s' "$ERLANG_NODE_ARG" | sed 's/[^A-Za-z0-9_.-]/-/g')"
  node_escaped="$(json_escape "$ERLANG_NODE_ARG")"
  ip_escaped="$(json_escape "$SELF_IP")"
  service_escaped="$(json_escape "$CONSUL_SERVICE_NAME")"
  domain_escaped="$(json_escape "$XMPP_DOMAIN")"
  payload="{\"ID\":\"$service_id\",\"Name\":\"$service_escaped\",\"Address\":\"$ip_escaped\",\"Port\":$CLUSTER_DIST_PORT,\"Meta\":{\"erlang_node\":\"$node_escaped\",\"xmpp_domain\":\"$domain_escaped\",\"epmd_port\":\"4369\",\"dist_port\":\"$CLUSTER_DIST_PORT\"},\"Check\":{\"TTL\":\"$CONSUL_CHECK_TTL\",\"Status\":\"critical\",\"Name\":\"ejabberd cluster readiness\"}}"
  consul_api PUT "/v1/agent/service/register" "$payload" >/dev/null
  SERVICE_ID="$service_id"
  export SERVICE_ID
  log "registered consul service id=$SERVICE_ID address=$SELF_IP dist=$CLUSTER_DIST_PORT node=$ERLANG_NODE_ARG"
}

consul_pass_service() {
  consul_api PUT "/v1/agent/check/pass/service:$SERVICE_ID" "cluster ready" >/dev/null || true
}

consul_fail_service() {
  consul_api PUT "/v1/agent/check/fail/service:$SERVICE_ID" "$1" >/dev/null || true
}

consul_heartbeat_loop() {
  while :; do
    consul_pass_service
    sleep "$CONSUL_HEARTBEAT_INTERVAL"
  done
}

consul_create_session() {
  session_name="$(json_escape "$SERVICE_ID")"
  payload="{\"Name\":\"$session_name\",\"TTL\":\"$CONSUL_CHECK_TTL\",\"Behavior\":\"release\"}"
  consul_api PUT "/v1/session/create" "$payload" | sed -n 's/.*\"ID\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p'
}

consul_renew_session_loop() {
  sid="$1"
  while :; do
    consul_api PUT "/v1/session/renew/$sid" "" >/dev/null || true
    sleep "$CONSUL_HEARTBEAT_INTERVAL"
  done
}

consul_get_seed() {
  consul_api GET "/v1/kv/${CONSUL_KV_PREFIX}/seed?raw" 2>/dev/null || true
}

consul_acquire_seed() {
  sid="$1"
  consul_api PUT "/v1/kv/${CONSUL_KV_PREFIX}/seed?acquire=$sid" "$ERLANG_NODE_ARG"
}

wait_ejabberd_ready() {
  i=1
  while [ "$i" -le "$CLUSTER_JOIN_RETRIES" ]; do
    if ejabberdctl status >/tmp/ejabberd-status 2>&1; then
      cat /tmp/ejabberd-status >&2
      return 0
    fi
    sleep "$CLUSTER_JOIN_INTERVAL"
    i=$((i + 1))
  done
  cat /tmp/ejabberd-status >&2 || true
  return 1
}

join_cluster_if_needed() {
  SESSION_ID="$(consul_create_session)"
  if [ -z "$SESSION_ID" ]; then
    log "failed to create consul session"
    return 1
  fi
  consul_renew_session_loop "$SESSION_ID" &
  SESSION_RENEW_PID=$!
  export SESSION_ID SESSION_RENEW_PID

  acquired="$(consul_acquire_seed "$SESSION_ID")"
  if [ "$acquired" = "true" ]; then
    CLUSTER_ROLE="seed"
    SEED_NODE="$ERLANG_NODE_ARG"
    log "acquired consul seed role: $SEED_NODE"
  else
    CLUSTER_ROLE="joiner"
    SEED_NODE=""
    i=1
    while [ "$i" -le "$CLUSTER_JOIN_RETRIES" ]; do
      SEED_NODE="$(consul_get_seed)"
      [ -n "$SEED_NODE" ] && break
      sleep "$CLUSTER_JOIN_INTERVAL"
      i=$((i + 1))
    done
    if [ -z "$SEED_NODE" ]; then
      log "no consul seed found"
      return 1
    fi
    log "using consul seed: $SEED_NODE"
  fi

  if [ "$CLUSTER_ROLE" = "joiner" ] && [ "$SEED_NODE" != "$ERLANG_NODE_ARG" ]; then
    i=1
    while [ "$i" -le "$CLUSTER_JOIN_RETRIES" ]; do
      if ejabberdctl join_cluster "$SEED_NODE"; then
        log "join_cluster succeeded seed=$SEED_NODE"
        break
      fi
      log "join_cluster failed attempt=$i seed=$SEED_NODE"
      sleep "$CLUSTER_JOIN_INTERVAL"
      i=$((i + 1))
    done
    if [ "$i" -gt "$CLUSTER_JOIN_RETRIES" ]; then
      log "join_cluster exhausted retries seed=$SEED_NODE"
      return 1
    fi
  fi

  i=1
  while [ "$i" -le "$CLUSTER_JOIN_RETRIES" ]; do
    list="$(ejabberdctl list_cluster || true)"
    printf '%s\n' "$list" >&2
    if printf '%s\n' "$list" | grep -F "$ERLANG_NODE_ARG" >/dev/null; then
      if [ "$CLUSTER_ROLE" != "joiner" ] || printf '%s\n' "$list" | grep -F "$SEED_NODE" >/dev/null; then
        return 0
      fi
    fi
    log "waiting for cluster membership attempt=$i role=$CLUSTER_ROLE seed=${SEED_NODE:-}"
    sleep "$CLUSTER_JOIN_INTERVAL"
    i=$((i + 1))
  done
  return 1
}

cluster_mode() {
  rm -f "$CLUSTER_READY_FILE"
  consul_register_service
  consul_fail_service "starting"

  log "starting ejabberd in cluster mode node=$ERLANG_NODE_ARG self_ip=$SELF_IP"
  /sbin/tini -- ejabberdctl "$@" &
  EJABBERD_PID=$!

  if ! wait_ejabberd_ready; then
    consul_fail_service "ejabberd failed to start"
    kill "$EJABBERD_PID" >/dev/null 2>&1 || true
    wait "$EJABBERD_PID" || true
    exit 1
  fi

  if ! join_cluster_if_needed; then
    consul_fail_service "cluster join failed"
    if [ "$CLUSTER_REQUIRE_JOIN" = "true" ]; then
      kill "$EJABBERD_PID" >/dev/null 2>&1 || true
      wait "$EJABBERD_PID" || true
      exit 1
    fi
  fi

  touch "$CLUSTER_READY_FILE"
  consul_pass_service
  consul_heartbeat_loop &
  HEARTBEAT_PID=$!
  export HEARTBEAT_PID
  log "cluster ready node=$ERLANG_NODE_ARG role=${CLUSTER_ROLE:-unknown}"
  wait "$EJABBERD_PID"
}

if [ "$CLUSTER_ENABLED" = "true" ]; then
  cluster_mode "$@"
fi

# Keep official image behaviour: run ejabberdctl in foreground by default.
exec /sbin/tini -- ejabberdctl "$@"
