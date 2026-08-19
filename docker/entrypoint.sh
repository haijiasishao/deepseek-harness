#!/usr/bin/env bash

set -Eeuo pipefail

readonly AUTH_DIR="/run/dsh-auth"
readonly AUTH_FILE="${AUTH_DIR}/.htpasswd"
readonly HARNESS_PORT=3080
readonly NGINX_CONFIG="/etc/nginx/nginx.conf"
readonly STARTUP_TIMEOUT_SECONDS=90

harness_pid=''
nginx_pid=''
password=''

log() {
  printf 'dsh-container: %s\n' "$*" >&2
}

stop_child() {
  local pid="$1"
  local signal="$2"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "-${signal}" "$pid" 2>/dev/null || true
  fi
}

reap_child() {
  local pid="$1"
  [[ -z "$pid" ]] || wait "$pid" >/dev/null 2>&1 || true
}

shutdown_children() {
  local signal="$1"
  trap - TERM INT
  stop_child "$harness_pid" "$signal"
  stop_child "$nginx_pid" "$signal"
  reap_child "$harness_pid"
  reap_child "$nginx_pid"
}

on_signal() {
  local signal="$1"
  shutdown_children "$signal"
  if [[ "$signal" == 'TERM' ]]; then
    exit 143
  fi
  exit 130
}

clear_credentials() {
  unset password WEB_PASSWORD WEB_USERNAME
}

trap clear_credentials EXIT
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

username=${WEB_USERNAME-}
password=${WEB_PASSWORD-}
unset WEB_PASSWORD WEB_USERNAME

if [[ ! $username =~ ^[A-Za-z0-9._-]+$ ]]; then
  log 'WEB_USERNAME must contain only letters, digits, dot, underscore, and hyphen'
  exit 64
fi

if (( ${#password} < 16 )); then
  log 'WEB_PASSWORD must be at least 16 characters'
  exit 64
fi

# htpasswd -i consumes one line, so reject values that would be truncated at a
# line ending instead of silently authenticating with a different password.
if [[ $password == *$'\n'* || $password == *$'\r'* ]]; then
  log 'WEB_PASSWORD must be a single line'
  exit 64
fi

umask 077
install -d -m 0700 "$AUTH_DIR"
rm -f "$AUTH_FILE"
if ! printf '%s\n' "$password" | htpasswd -B -C 12 -i -c "$AUTH_FILE" "$username" >/dev/null 2>&1; then
  unset password
  log 'failed to create the Basic Auth file'
  exit 1
fi
chmod 0600 "$AUTH_FILE"
unset password

if ! nginx -t -q -c "$NGINX_CONFIG" >/dev/null 2>&1; then
  log 'nginx configuration validation failed'
  exit 1
fi

run_dsh() {
  exec node /opt/dsh/apps/cli/lib/bin.js "$@"
}

dsh() {
  run_dsh "$@"
}

dsh web --host 127.0.0.1 --port "$HARNESS_PORT" &
harness_pid=$!

ready=0
ready_deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
while (( SECONDS < ready_deadline )); do
  if curl --fail --silent --show-error --max-time 2 \
      "http://127.0.0.1:${HARNESS_PORT}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi

  harness_state="$(ps -o stat= -p "$harness_pid" 2>/dev/null || true)"
  if [[ -z "$harness_state" || "$harness_state" == Z* ]]; then
    if wait "$harness_pid"; then
      harness_status=0
    else
      harness_status=$?
    fi
    log "dsh web exited before readiness with status ${harness_status}"
    exit 1
  fi
  sleep 1
done

if (( ready == 0 )); then
  log "dsh web did not become ready within ${STARTUP_TIMEOUT_SECONDS}s"
  stop_child "$harness_pid" TERM
  reap_child "$harness_pid"
  exit 1
fi

nginx -c "$NGINX_CONFIG" -g 'daemon off;' &
nginx_pid=$!

child_pid=''
child_status=1
if wait -n -p child_pid "$harness_pid" "$nginx_pid"; then
  child_status=0
else
  child_status=$?
fi

if [[ "$child_pid" == "$harness_pid" ]]; then
  log "dsh web exited with status ${child_status}"
  stop_child "$nginx_pid" TERM
  reap_child "$nginx_pid"
elif [[ "$child_pid" == "$nginx_pid" ]]; then
  log "nginx exited with status ${child_status}"
  stop_child "$harness_pid" TERM
  reap_child "$harness_pid"
else
  log 'a supervised child exited without an identifiable PID'
  stop_child "$harness_pid" TERM
  stop_child "$nginx_pid" TERM
  reap_child "$harness_pid"
  reap_child "$nginx_pid"
  child_status=1
fi

exit "$child_status"
