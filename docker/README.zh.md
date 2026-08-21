# DeepSeek Harness Docker 镜像

[English](README.md) | 中文

此镜像在同一个容器中运行已构建的 Web profile 和 Nginx 前端。Harness 只监听容器内的 `127.0.0.1:3080`；Nginx 是唯一暴露的服务，监听 `8080` 并为整站启用 HTTP Basic Auth。`/healthz` 关闭身份验证，但只允许容器环回地址访问，并将请求代理到 Harness。

入口脚本使用固定的 90 秒就绪截止时间。

## 部署自动化

定时同步从 `deploy` 分支运行，且只将官方 upstream 的 `master` 快进同步到本仓库，不自动构建或发布镜像。请将 `deploy` 设置为仓库默认分支，因为 GitHub 从默认分支运行定时工作流。需要构建、smoke 测试和发布镜像时，必须显式手动执行 `workflow_dispatch`。Docker 文件来自 `deploy`，镜像源码则是同步后的精确 `master` 提交。

## 构建

从仓库根目录运行构建，使 Dockerfile 可以使用工作区锁文件和所有包源码。

```sh
docker build \
  --build-arg "DSH_CLIENT_COMMIT_HASH=$(git rev-parse HEAD)" \
  --build-arg DSH_CLIENT_REMOTE_SETTINGS=1 \
  --file docker/Dockerfile \
  --tag deepseek-harness:local .
```

构建使用 Node `22-bookworm-slim`、Corepack、pnpm `11.7.0`、`pnpm install --frozen-lockfile` 和 `pnpm run build`。

部署覆盖层会在镜像构建前应用其纳入版本控制的源码补丁。

部署镜像将 `DSH_CLIENT_REMOTE_SETTINGS=1` 注入客户端构建，因此通过现有 Nginx Basic Auth 认证的远程浏览器可以使用 Host 持久化设置。官方源码默认让非环回客户端使用进程内 memory。

如需在本地构建中保持官方的非环回 memory 行为，可改为传入 `--build-arg DSH_CLIENT_REMOTE_SETTINGS=0`。这是构建期客户端开关，不会改变服务器的 API 信任规则。

## 官方命令工具链

最终镜像保留官方项目在 Linux 环境下使用的命令工具链，而不只是在构建阶段提供：Node.js 及其 `npm`/`npx`、Corepack 和 pnpm `11.7.0`、`dsh` CLI、Git、Bash、Python 3、curl、ripgrep、SSH 客户端、zip/unzip，以及 `make`、`gcc`、`g++` 原生构建工具。工作区中的 `tsx`、`tsc`、`tsdown`、`vitest`、`oxlint`、`jscpd`、`knip` 和 VitePress 工具也保留在 `/opt/dsh` 下。

镜像内的 `pnpm` 和 `pnpx` 包装器只会让各自的包管理器子进程默认使用 `CI=true`，因此没有 TTY 时也能执行 profile 维护；确需交互式 pnpm 确认时，显式传入 `CI=false` 即可。

这支持 `dsh web`、profile 启动和配置导出、`dsh plugin --profile ... add/remove/update/why`，以及官方 `pnpm run` 构建、类型检查、测试、Lint 和验证命令；外部插件在安装自身依赖后也可以在容器内构建。Windows/Wine 专用门禁不属于 Linux 运行时契约。外部插件源码及其开发依赖不会预置到镜像中，应在挂载的 `/home/dsh` 插件目录内安装，或直接使用带完整构建产物的 Release 包。

## 运行

在版本控制之外创建环境文件。`WEB_USERNAME` 只能包含字母、数字、`.`、`_` 和 `-`；`WEB_PASSWORD` 至少需要 8 个字符。

入口脚本会对密码进行哈希，并从子进程环境中删除密码，但 Docker 仍会记录容器的初始环境。拥有 Docker 管理权限的人员可以查看该密码，因此应使用独立凭证并严格限制 Docker 管理权限。

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

`/home/dsh` 卷保存 Harness home，`/workspace` 卷是默认工作目录。创建并为 uid `10001` 设置权限后，也可以用 `--volume "$PWD/workspace:/workspace"` 将工作区卷替换为宿主机 bind mount。

## 验证

未认证的站点请求必须返回 `401`；使用示例凭证的请求必须返回 `200`。

```sh
curl --include --silent --output /dev/null --write-out '%{http_code}\n' http://127.0.0.1:8080/
curl --include --silent --output /dev/null --write-out '%{http_code}\n' --user 'dsh:change-this-password-please' http://127.0.0.1:8080/
```

容器内部通过 Nginx 发送的健康请求必须在不提供凭证时返回 `200`。容器外部请求必须返回 `403`，因为 `/healthz` 不是公开端点。

```sh
docker exec deepseek-harness curl --include --silent --output /dev/null --write-out '%{http_code}\n' http://127.0.0.1:8080/healthz
curl --include --silent --output /dev/null --write-out '%{http_code}\n' http://127.0.0.1:8080/healthz
```

镜像不会发布 `3080` 端口。直接使用容器时保持 `127.0.0.1` 宿主机绑定；需要远程访问时，应通过终止 TLS 的可信反向代理发布 Nginx。

## 修改密码

Docker 在创建容器时注入环境文件的值，因此编辑 `dsh.env` 不会改变现有容器。修改 `WEB_PASSWORD` 后，使用相同的卷参数重建容器；删除容器不会删除命名卷。

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

此设置中的 Basic Auth 和代理 Web 流量在内部使用明文 HTTP。不要直接在不可信网络上暴露 `8080`；请在可信反向代理上终止 HTTPS，并单独保护其健康检查和证书配置。
