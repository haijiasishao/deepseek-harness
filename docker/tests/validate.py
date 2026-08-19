#!/usr/bin/env python3
"""Validate Docker packaging security and lifecycle contracts without Docker."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def fail(message: str) -> None:
    print(f"docker validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing {relative}")
    return path.read_text(encoding="utf-8")


def require(text: str, pattern: str, description: str, flags: int = 0) -> None:
    if re.search(pattern, text, flags) is None:
        fail(description)


def forbid(text: str, pattern: str, description: str, flags: int = 0) -> None:
    if re.search(pattern, text, flags) is not None:
        fail(description)


dockerfile = read("docker/Dockerfile")
entrypoint = read("docker/entrypoint.sh")
nginx = read("docker/nginx.conf")
smoke = read("docker/tests/smoke.sh")
readme = read("docker/README.md")
readme_zh = read("docker/README.zh.md")
read("docker/Dockerfile.dockerignore")

require(dockerfile, r"^FROM node:22-bookworm-slim AS build$", "the build stage must use node:22-bookworm-slim", re.MULTILINE)
require(dockerfile, r"^FROM node:22-bookworm-slim AS runtime$", "the runtime stage must use node:22-bookworm-slim", re.MULTILINE)
require(dockerfile, r"corepack prepare pnpm@11\.7\.0 --activate", "Corepack must activate pnpm 11.7.0")
require(dockerfile, r'test "\$\(pnpm --version\)" = "11\.7\.0"', "the image must verify the pnpm version")
require(dockerfile, r"pnpm install --frozen-lockfile", "the build must use the lockfile immutably")
require(dockerfile, r"pnpm run build", "the official source must be built")
for package in ("nginx", "tini", "curl", "apache2-utils", "bash", "ca-certificates", "procps"):
    require(dockerfile, rf"\b{re.escape(package)}\b", f"{package} must be installed in the image")
require(dockerfile, r"^WORKDIR /workspace$", "the runtime work directory must be /workspace", re.MULTILINE)
require(dockerfile, r"^USER dsh$", "the runtime must use the non-root dsh user", re.MULTILINE)
require(dockerfile, r"VOLUME \[\"/home/dsh\", \"/workspace\"\]", "the home and workspace volumes must be declared")
require(dockerfile, r"^EXPOSE 8080$", "only port 8080 may be exposed", re.MULTILINE)
for exposed in re.findall(r"^\s*EXPOSE\s+([^\s#]+)", dockerfile, re.MULTILINE):
    if exposed != "8080":
        fail(f"unexpected exposed port {exposed}")
forbidden_expose = r"^\s*EXPOSE\s+[^\n]*\b3080\b"
forbid(dockerfile, forbidden_expose, "the Harness port must not be exposed", re.MULTILINE)
require(dockerfile, r"HEALTHCHECK[\s\S]*?/healthz", "the image must health-check /healthz")
require(dockerfile, r"ENTRYPOINT \[\"/usr/bin/tini\", \"--\"", "tini must supervise the entrypoint")

require(entrypoint, r"^set -Eeuo pipefail$", "the entrypoint must use strict shell error handling", re.MULTILINE)
require(entrypoint, r"\^\[A-Za-z0-9\._-\]\+\$", "WEB_USERNAME must use the required character allow-list")
require(entrypoint, r"\$\{#password\}\s*<\s*16", "WEB_PASSWORD must have a 16-character minimum")
require(entrypoint, r"htpasswd\s+-B\s+-C\s+12\s+-i\s+-c", "htpasswd must use bcrypt cost 12 and read stdin")
forbid(entrypoint, r"htpasswd[^\n]*\s-b(?:\s|$)", "htpasswd must not receive a password with -b")
require(entrypoint, r"unset WEB_PASSWORD", "WEB_PASSWORD must be unset before child processes start")
require(entrypoint, r"unset password", "the copied password must be cleared")
require(entrypoint, r"^dsh web --host 127\.0\.0\.1 --port \"\$HARNESS_PORT\" &$", "dsh must bind the Harness to loopback port 3080", re.MULTILINE)
require(entrypoint, r"readonly STARTUP_TIMEOUT_SECONDS=90", "startup must use a fixed 90-second timeout")
require(entrypoint, r"127\.0\.0\.1:\$\{HARNESS_PORT\}/healthz", "startup must probe Harness readiness")
require(entrypoint, r"wait -n -p child_pid", "the entrypoint must wait for either child")
require(entrypoint, r"trap 'on_signal TERM' TERM", "TERM must be trapped")
require(entrypoint, r"trap 'on_signal INT' INT", "INT must be trapped")
require(entrypoint, r"stop_child", "child shutdown must propagate signals")
forbid(entrypoint, r"\bset -x\b", "the entrypoint must not enable shell tracing")
for line in entrypoint.splitlines():
    if (
        re.search(r"(?:echo|printf|log)", line)
        and re.search(r"(?:WEB_PASSWORD|\$password)", line)
        and re.search(r">&\s*[12]", line)
        and not re.search(r"\|\s*htpasswd\b", line)
    ):
        fail("the entrypoint must not print credentials")

require(nginx, r"^\s*listen 8080;$", "nginx must listen on port 8080", re.MULTILINE)
require(nginx, r"auth_basic \"DeepSeek Harness\";", "the proxy must require Basic Auth")
require(nginx, r"auth_basic_user_file /run/dsh-auth/\.htpasswd;", "nginx must use the generated password file")
health_match = re.search(r"location\s*=\s*/healthz\s*\{(?P<body>.*?)^\s*\}", nginx, re.DOTALL | re.MULTILINE)
if health_match is None:
    fail("nginx must define an exact /healthz location")
health = health_match.group("body")
require(health, r"allow 127\.0\.0\.1;", "/healthz must allow container IPv4 loopback")
require(health, r"allow ::1;", "/healthz must allow container IPv6 loopback")
require(health, r"deny all;", "/healthz must deny non-loopback callers")
require(health, r"auth_basic off;", "/healthz must be unauthenticated")
require(nginx, r"server 127\.0\.0\.1:3080;", "the Harness upstream must stay on loopback")
require(health, r"proxy_pass http://harness;", "/healthz must proxy to the Harness")
forbid(health, r"\breturn\s+200\b", "/healthz must reflect the upstream rather than return a fixed status")
require(nginx, r"map \$http_upgrade \$connection_upgrade", "WebSocket upgrade mapping must be configured")
require(nginx, r"proxy_set_header Upgrade \$http_upgrade;", "WebSocket upgrades must reach the Harness")
require(nginx, r"proxy_set_header Connection \$connection_upgrade;", "WebSocket connection semantics must reach the Harness")
require(nginx, r"proxy_buffering off;", "SSE responses must not be buffered")
require(nginx, r"proxy_request_buffering off;", "streaming requests must not be buffered")
require(nginx, r"proxy_read_timeout 24h;", "long-running responses need a long read timeout")
require(nginx, r"proxy_send_timeout 24h;", "long-running requests need a long send timeout")
require(nginx, r"proxy_pass http://harness;", "the proxy must target the Harness upstream")
require(nginx, r"proxy_set_header Host 127\.0\.0\.1:3080;", "the authenticated proxy must normalize the upstream Host for the Harness trust fence")
require(nginx, r"proxy_set_header Origin \"\";", "the authenticated proxy must remove the external Origin before the loopback trust fence")
require(nginx, r"proxy_set_header Authorization \"\";", "Basic credentials must not be forwarded into the Harness")
for temp_name in ("client-body", "proxy", "fastcgi", "uwsgi", "scgi"):
    require(nginx, rf"/tmp/dsh-nginx-{temp_name}", f"nginx {temp_name} temporary files must use a non-root writable path")
    require(dockerfile, rf"/tmp/dsh-nginx-{temp_name}", f"the image must create the nginx {temp_name} temporary path")
forbid(nginx, r"^\s*listen\s+[^;]*\b3080\b", "nginx must not listen on the Harness port", re.MULTILINE)

require(smoke, r"^set -Eeuo pipefail$", "the smoke test must use strict shell error handling", re.MULTILINE)
require(smoke, r"--env-file", "the smoke test must pass credentials through an env file")
require(smoke, r"expect_code 401", "the smoke test must check unauthenticated rejection")
require(smoke, r"wrong_netrc", "the smoke test must check an incorrect password")
require(smoke, r"expect_code 200", "the smoke test must check successful responses")
require(smoke, r"expect_code 403\s+\"\$base_url/healthz\"", "the smoke test must reject external /healthz")
require(smoke, r"expect_internal_code 200", "the smoke test must check internal /healthz")
require(smoke, r"docker exec[^\n]*curl", "the smoke test must use docker exec for internal health")
require(smoke, r"expect_not_code 403[\s\S]*?/api/docker-smoke-nonexistent", "the smoke test must exercise the API trust fence through an external Host and Origin")
require(smoke, r"docker restart", "the smoke test must check persistence across restart")
require(smoke, r"/home/dsh", "the smoke test must mount the Harness home")
require(smoke, r"/workspace", "the smoke test must mount the workspace")
require(smoke, r"NetworkSettings\.Ports", "the smoke test must inspect published ports")
forbid(smoke, r"\bset -x\b", "the smoke test must not enable shell tracing")
forbid(smoke, r"(?:echo|printf)[^\n]*(?:WEB_PASSWORD|\$password)[^\n]*>&[12]", "the smoke test must not log credentials")

readme_lower = readme.lower()
readme_zh_lower = readme_zh.lower()
for phrase in (
    "--env-file",
    "/home/dsh",
    "/workspace",
    "401",
    "200",
    "403",
    "docker exec",
    "recreate",
    "https",
    "deploy",
    "official",
    "fixed 90-second",
):
    if phrase not in readme_lower:
        fail(f"the README must document {phrase}")
for phrase in ("--env-file", "/home/dsh", "/workspace", "401", "200", "403", "docker exec", "90", "deploy"):
    if phrase not in readme_zh_lower:
        fail(f"the Chinese README must document {phrase}")
if "HARNESS_READY_TIMEOUT_SECONDS" in readme_zh:
    fail("the Chinese README must not document an unsupported timeout override")

print("docker static validation passed")
