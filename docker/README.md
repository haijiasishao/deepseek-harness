# DeepSeek Harness Docker image

English | [中文](README.zh.md)

The image runs the built Web profile and an nginx front end in one container. The Harness listens only on `127.0.0.1:3080`; nginx is the only exposed service and listens on port `8080` with HTTP Basic Authentication. `/healthz` disables authentication but is restricted to container loopback addresses and is proxied to the Harness.

The entrypoint uses a fixed 90-second readiness deadline.

## Deployment automation

Scheduled synchronization and image publication run from the `deploy` branch. Set `deploy` as the repository default branch because GitHub runs scheduled workflows from the default branch. The workflow fast-forwards `master` to the official upstream `master`, so `master` is a pure official mirror. Docker files come from `deploy`, while the image source is the exact synchronized `master` commit.

## Build

Run the build from the repository root so the Dockerfile can use the workspace lockfile and all package sources.

```sh
docker build --file docker/Dockerfile --tag deepseek-harness:local .
```

The build uses Node `22-bookworm-slim`, Corepack with pnpm `11.7.0`, `pnpm install --frozen-lockfile`, and `pnpm run build`.

## Run

Create an environment file outside version control. `WEB_USERNAME` may contain only letters, digits, `.`, `_`, and `-`; `WEB_PASSWORD` must contain at least 16 characters.

The entrypoint hashes the password and removes it from child-process environments, but Docker still records the container's initial environment. Anyone with Docker administrative access can inspect it, so use a dedicated credential and restrict Docker access.

```sh
cat > dsh.env <<'EOF'
DEEPSEEK_API_KEY=replace-with-your-deepseek-api-key
WEB_USERNAME=dsh
WEB_PASSWORD=change-this-password-please
EOF
chmod 600 dsh.env

docker volume create dsh-home >/dev/null
docker volume create dsh-workspace >/dev/null
docker run --detach \
  --name deepseek-harness \
  --env-file "$PWD/dsh.env" \
  --volume dsh-home:/home/dsh \
  --volume dsh-workspace:/workspace \
  --publish 127.0.0.1:8080:8080 \
  deepseek-harness:local
```

The `/home/dsh` volume holds the Harness home and the `/workspace` volume is the default working tree. A host bind mount can replace the workspace volume, for example `--volume "$PWD/workspace:/workspace"` after creating and permissioning that directory for uid `10001`.

## Verify

The unauthenticated site request must return `401`; the request with the example credentials must return `200`.

```sh
curl --include --silent --output /dev/null --write-out '%{http_code}\n' http://127.0.0.1:8080/
curl --include --silent --output /dev/null --write-out '%{http_code}\n' --user 'dsh:change-this-password-please' http://127.0.0.1:8080/
```

The container-internal health request must return `200` through nginx without credentials. A request from outside the container must return `403` because `/healthz` is not a public endpoint.

```sh
docker exec deepseek-harness curl --include --silent --output /dev/null --write-out '%{http_code}\n' http://127.0.0.1:8080/healthz
curl --include --silent --output /dev/null --write-out '%{http_code}\n' http://127.0.0.1:8080/healthz
```

The image does not publish port `3080`. Keep the `127.0.0.1` host binding when the container is used directly; publish nginx through a TLS-terminating reverse proxy for remote access.

## Change the password

Docker supplies environment-file values when the container is created, so editing `dsh.env` does not change an existing container. Recreate the container with the same volume arguments after changing `WEB_PASSWORD`; removing the container does not remove named volumes.

```sh
docker rm --force deepseek-harness
docker run --detach \
  --name deepseek-harness \
  --env-file "$PWD/dsh.env" \
  --volume dsh-home:/home/dsh \
  --volume dsh-workspace:/workspace \
  --publish 127.0.0.1:8080:8080 \
  deepseek-harness:local
```

Basic Authentication and the proxied Web traffic are plain HTTP inside this setup. Do not expose port `8080` directly on an untrusted network; terminate HTTPS at a trusted reverse proxy and protect its health-check and certificate configuration separately.
