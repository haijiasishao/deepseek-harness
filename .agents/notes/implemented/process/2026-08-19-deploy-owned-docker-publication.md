# Agent Note: Deploy-owned Docker publication over an official master mirror

Status: implemented

English | [中文](2026-08-19-deploy-owned-docker-publication.zh.md)

## Problem

The Docker deployment layer needs to track official source changes without allowing a deploy-owned branch to alter the official source mirror or publish an unverified image. The public health route also needs to report Harness readiness without becoming an unauthenticated external service.

## Decision

`deploy` is the repository default branch for the scheduled workflow. The sync job fetches `master` from the official upstream, requires the fork's `master` to be an ancestor, and pushes the upstream commit through Git's normal fast-forward path with `contents: write` as its only elevated permission. `master` therefore remains a pure official mirror.

The deploy branch removes the upstream real-API `e2e.yml` workflow because that workflow also has a default-branch schedule and requires an official-repository secret. The official workflow remains unchanged on `master`; removing it only from `deploy` prevents a secret-less nightly fork run from failing alongside the Docker publication schedule.

The build and publish jobs check out the exact synchronized upstream SHA and overlay only `docker/` from `origin/deploy`. Python validation and Bash syntax checks run before the amd64 Docker smoke test. Publication waits for that smoke test, then pushes amd64 and arm64 images to GHCR with `latest` and the seven-character `master-<SHA>` tag, OCI source/revision/license labels, GitHub Actions build cache, and `GITHUB_TOKEN` authentication.

Nginx permits `/healthz` only from `127.0.0.1` and `::1`, disables Basic Auth for that location, and proxies the request to Harness. For authenticated application traffic it normalizes the upstream Host to loopback, removes the external Origin so the Harness loopback trust fence remains coherent behind the proxy, and strips the consumed Basic `Authorization` header before the request reaches Harness. The smoke test checks internal health, external denial, and API access through a non-loopback browser authority. The entrypoint uses a fixed 90-second readiness deadline.

## Alternatives considered

**Force-update the fork's `master`.** Rejected because a divergence indicates an unsafe change to the official mirror; the ancestor check and ordinary push preserve that evidence and stop instead.

**Build the image from `deploy` alone.** Rejected because Docker packaging belongs to `deploy`, while source reproducibility and the mirror guarantee require the exact synchronized upstream commit as the build base.

**Leave `/healthz` public because it has no credentials.** Rejected because an unauthenticated readiness proxy still exposes service state externally; loopback allow rules preserve Docker's internal health check without making the route public.

## Consequences

The scheduled workflow is safe only when `deploy` is the default branch, and a diverged mirror requires operator reconciliation before another run can publish. A failed validation, smoke test, or publication build cannot advance `latest` because publication is downstream of all pre-publication checks. Operators must use `docker exec` for health verification and place HTTPS in front of any remotely reachable nginx endpoint.
