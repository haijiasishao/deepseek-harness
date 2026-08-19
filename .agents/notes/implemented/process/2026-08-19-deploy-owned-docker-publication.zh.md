# Agent Note: 由 deploy 负责发布 Docker 并保持官方 master 纯镜像

Status: implemented

[English](2026-08-19-deploy-owned-docker-publication.md) | 中文

## 问题

Docker 部署层需要跟踪官方源码变化，同时不能让由部署方拥有的分支修改官方源码镜像或发布未经验证的镜像。公开的健康路径还需要报告 Harness 是否就绪，但不能因此成为外部可访问的未认证服务。

## 决策

定时工作流以 `deploy` 作为仓库默认分支运行。同步任务从官方 upstream 获取 `master`，要求 fork 的 `master` 是其祖先，然后通过 Git 的普通快进路径推送 upstream 提交，并且只有 `contents: write` 这一项提升权限。因此 `master` 始终是官方内容的纯镜像。

`deploy` 分支删除了 upstream 的真实 API `e2e.yml` 工作流，因为该工作流同样带有默认分支定时计划，并依赖官方仓库密钥。官方工作流在 `master` 上保持不变；仅从 `deploy` 删除它，可以避免没有密钥的 Fork 夜间任务与 Docker 发布计划同时运行并失败。

构建和发布任务检出同步后的精确 upstream SHA，只从 `origin/deploy` 覆盖 `docker/`，并在安装依赖和构建镜像前应用 Docker 中纳入版本控制的源码补丁。Python 校验和 Bash 语法检查在 amd64 Docker 冒烟测试之前运行。发布等待该冒烟测试成功，然后向 GHCR 推送 amd64 与 arm64 镜像，使用 `latest` 和七字符的 `master-<SHA>` 标签、OCI 源码/版本/许可证标签、GitHub Actions 构建缓存以及 `GITHUB_TOKEN` 身份验证。

Nginx 只允许来自 `127.0.0.1` 和 `::1` 的 `/healthz` 请求，关闭该路径的 Basic Auth，并将请求代理到 Harness。对于已认证的应用流量，Nginx 将上游 Host 规范化为环回地址，移除外部 Origin 以保持反向代理后的 Harness 环回信任围栏一致，并在请求进入 Harness 前剥离已经消费的 Basic `Authorization` 头。冒烟测试同时检查内部健康、外部拒绝以及非环回浏览器 authority 下的 API 访问。入口脚本使用固定的 90 秒就绪截止时间。

## 曾考虑的替代方案

**强制更新 fork 的 `master`。** 不予采纳，因为分叉表示官方镜像发生了不安全的变化；祖先检查和普通推送会保留这个证据并停止运行。

**只从 `deploy` 构建镜像。** 不予采纳，因为 Docker 打包属于 `deploy`，而源码可复现性和镜像保证要求以同步后的精确 upstream 提交作为构建基础。

**因为 `/healthz` 不需要凭证而保持公开。** 不予采纳，因为未认证的就绪代理仍会向外部暴露服务状态；环回 allow 规则保留 Docker 内部健康检查，同时不使该路径公开。

## 后果

只有在 `deploy` 是默认分支时，定时工作流才按预期安全运行；镜像发生分叉时，必须由操作者先处理分叉，之后才可以再次发布。验证、冒烟测试或发布构建失败时，发布任务不会运行，因此不会推进 `latest`。操作者必须通过 `docker exec` 检查健康状态，并在任何可从远程访问的 Nginx 端点前配置 HTTPS。
