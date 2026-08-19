#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' 'docker smoke test skipped: docker is not installed'
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  printf '%s\n' 'docker smoke test skipped: no writable Docker daemon is available'
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '%s\n' 'docker smoke test skipped: curl is not installed on the host'
  exit 0
fi

fail() {
  printf 'docker smoke test failed: %s\n' "$1" >&2
  exit 1
}

umask 077
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dsh-docker-smoke.XXXXXX")"
env_file="$test_root/dsh.env"
home_dir="$test_root/home"
workspace_dir="$test_root/workspace"
netrc="$test_root/netrc"
wrong_netrc="$test_root/wrong_netrc"
mkdir -p "$home_dir" "$workspace_dir"
chmod 0777 "$home_dir" "$workspace_dir"

image="dsh-docker-smoke:${$}"
container="dsh-docker-smoke-${$}"
password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"

cleanup() {
  unset password
  docker rm --force "$container" >/dev/null 2>&1 || true
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT

printf 'WEB_USERNAME=dsh\nWEB_PASSWORD=%s\n' "$password" > "$env_file"
printf 'machine 127.0.0.1 login dsh password %s\n' "$password" > "$netrc"
printf '%s\n' 'machine 127.0.0.1 login dsh password definitely-wrong-password' > "$wrong_netrc"
chmod 600 "$env_file" "$netrc" "$wrong_netrc"

docker build --platform linux/amd64 --file "$REPO_DIR/docker/Dockerfile" --tag "$image" "$REPO_DIR" >/dev/null
docker run --detach \
  --name "$container" \
  --platform linux/amd64 \
  --env-file "$env_file" \
  --publish 127.0.0.1::8080 \
  --volume "$home_dir:/home/dsh" \
  --volume "$workspace_dir:/workspace" \
  "$image" >/dev/null

ports="$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$container")"
if [[ "$ports" == *3080* ]]; then
  fail 'the container published the private Harness port 3080'
fi

host_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$container")"
[[ -n "$host_port" ]] || fail 'Docker did not publish the nginx port'
base_url="http://127.0.0.1:${host_port}"

http_code() {
  local url="$1"
  shift
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 5 "$@" "$url" 2>/dev/null || true
}

expect_code() {
  local expected="$1"
  local url="$2"
  shift 2
  local actual
  actual="$(http_code "$url" "$@")"
  [[ "$actual" == "$expected" ]] || fail "expected HTTP ${expected} from ${url}, got ${actual}"
}

expect_not_code() {
  local rejected="$1"
  local url="$2"
  shift 2
  local actual
  actual="$(http_code "$url" "$@")"
  [[ "$actual" != "$rejected" ]] || fail "did not expect HTTP ${rejected} from ${url}"
}

container_http_code() {
  local url="$1"
  docker exec "$container" curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 5 "$url" 2>/dev/null || true
}

expect_internal_code() {
  local expected="$1"
  local url="$2"
  local actual
  actual="$(container_http_code "$url")"
  [[ "$actual" == "$expected" ]] || fail "expected internal HTTP ${expected} from ${url}, got ${actual}"
}

wait_for_internal_code() {
  local expected="$1"
  local url="$2"
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if [[ "$(container_http_code "$url")" == "$expected" ]]; then
      return 0
    fi
    sleep 1
  done
  fail "timed out waiting for internal HTTP ${expected} from ${url}"
}

wait_for_internal_code 200 http://127.0.0.1:8080/healthz
expect_internal_code 200 http://127.0.0.1:8080/healthz
expect_code 401 "$base_url/"
expect_code 401 "$base_url/" --netrc-file "$wrong_netrc"
expect_code 200 "$base_url/" --netrc-file "$netrc"
expect_code 403 "$base_url/healthz"
expect_not_code 403 "$base_url/api/docker-smoke-nonexistent" \
  --netrc-file "$netrc" \
  --header 'Host: harness.example' \
  --header 'Origin: http://harness.example'

docker exec "$container" sh -c 'printf %s persistent-workspace > /workspace/.dsh-smoke-marker && printf %s persistent-home > /home/dsh/.dsh-smoke-marker'
docker restart "$container" >/dev/null
wait_for_internal_code 200 http://127.0.0.1:8080/healthz
expect_code 403 "$base_url/healthz"
expect_code 200 "$base_url/" --netrc-file "$netrc"
[[ "$(docker exec "$container" cat /workspace/.dsh-smoke-marker)" == 'persistent-workspace' ]] || fail 'the workspace volume did not persist'
[[ "$(docker exec "$container" cat /home/dsh/.dsh-smoke-marker)" == 'persistent-home' ]] || fail 'the home volume did not persist'

printf '%s\n' 'docker smoke test passed'
