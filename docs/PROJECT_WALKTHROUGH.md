# Project walkthrough: what I did, why, and how to check it

This document is for anyone reviewing this repository. It explains the assessment, every
change I made, the reasoning behind each decision, and how to verify each claim yourself.
You don't need to install anything to follow it: every result links to a file or a
public GitHub Actions run.

**Contents**
1. [The assignment in short](#1-the-assignment-in-short)
2. [How the pieces fit together](#2-how-the-pieces-fit-together)
3. [Task 1: Linux, log analysis and Git](#3-task-1-linux-log-analysis-and-git)
4. [Task 2: Docker image and Compose](#4-task-2-docker-image-and-compose)
5. [Task 3: CI/CD with GitHub Actions](#5-task-3-cicd-with-github-actions)
6. [Task 4: Kubernetes workload and rollout](#6-task-4-kubernetes-workload-and-rollout)
7. [Task 5: Terraform configuration as code](#7-task-5-terraform-configuration-as-code)
8. [Task 6: Monitoring, security and recovery](#8-task-6-monitoring-security-and-recovery)
9. [Task 7: Documentation and evidence](#9-task-7-documentation-and-evidence)
10. [How to verify everything in 5 minutes](#10-how-to-verify-everything-in-5-minutes)
11. [Design decisions in question-and-answer form](#11-design-decisions-in-question-and-answer-form)
12. [Limitations and what I'd do next](#12-limitations-and-what-id-do-next)
13. [Git history](#13-git-history)

---

## 1. The assignment in short

The **DevOps Fresher Assessment, Set D** provides a small Python HTTP service, the *Campus Library
Book Lookup API*, with its unit tests, a sample access log and an empty infrastructure skeleton.
The task is to build everything around the app: packaging, automated testing, deployment,
configuration, monitoring and incident handling. It's graded in 7 parts worth 70 marks.

The application itself (`app/server.py`) and its tests (`tests/test_server.py`) were provided and
**were not modified**. You can confirm this by comparing them with the first commit
(`chore: add provided starter kit`).

| Endpoint | Behaviour |
|---|---|
| `GET /healthz` | 200 while the process is responsive |
| `GET /readyz` | 200 normally, **503 when `FAIL_MODE=1`** |
| `GET /info` | JSON with `APP_NAME` and `APP_ENV` |
| `GET /api/books?code=BK-101` | 200 with `"status": "available"` |
| `GET /unknown` | 404 |

`FAIL_MODE` is a switch built into the app for this exercise. It's used to simulate a bad release in Task 4.

## 2. How the pieces fit together

```
SETTINGS     infra/*.tf  --terraform apply-->  generated/service.env  (APP_NAME, APP_ENV, LOG_LEVEL, PORT, FAIL_MODE)

LOCAL        Dockerfile --docker build--> image --docker compose up (reads service.env)--> 127.0.0.1:8080

PIPELINE     git push / pull request --> [syntax check + 7 unit tests] --only if green--> [docker build, tag = commit SHA]

KUBERNETES   image --kind load--> cluster --kubectl apply k8s/--> Namespace + ConfigMap + Deployment (2 Pods) + Service (80->8080)

INCIDENT     FAIL_MODE=1 release --> new Pod never Ready (503) --> diagnose --> rollout undo --> 2/2 Ready
```

The same configuration values flow through every stage. Terraform generates them for Compose,
and the Kubernetes ConfigMap holds the same keys.

---

## 3. Task 1: Linux, log analysis and Git

**Files:** [`scripts/analyze_logs.sh`](../scripts/analyze_logs.sh) · **Evidence:** [`evidence/01-linux-log-analysis.txt`](../evidence/01-linux-log-analysis.txt)

Each log line looks like `2026-11-23T09:00:00Z 200 GET /healthz duration_ms=15`, so field `$2`
is the status and `$4` is the route.

```bash
wc -l < logs/access.log                                               # 24 total requests
awk '$2 ~ /^4/' logs/access.log | wc -l                               # 4  HTTP 4xx (all 404 /unknown)
awk '$2 ~ /^5/' logs/access.log | wc -l                               # 2  HTTP 5xx (503 /readyz, 503 /api/books)
awk '{print $4}' logs/access.log | sort | uniq -c | sort -rn | head -3 # top routes
#   8 /healthz   6 /api/books?code=BK-101   5 /readyz
```

`scripts/analyze_logs.sh <path>` prints the same figures plus the **5xx rate (2/24 = 8.33 %)**.
- It uses `set -euo pipefail`, so it stops on errors, unset variables and pipe failures.
- **Missing or unreadable file:** it writes the error to stderr and **exits 1**. **No argument:** it prints usage and exits 2.
- It matches strict 3-digit status codes (`^4[0-9][0-9]$`) and ignores blank lines.

**Git practice.** The untouched starter kit was committed to `main` first. All the work was then done
on `feature/devops-assessment` in small, single-purpose commits and merged through
[pull request #1](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/pull/1). Credentials and generated
state are excluded by [`.gitignore`](../.gitignore) (`*.tfstate*`, `.terraform/`, `*.tfvars`,
`generated/service.env`, `.env`). Before the repository was made public, I scanned the whole history for
tokens, keys and state files, and none were found.

## 4. Task 2: Docker image and Compose

**Files:** [`Dockerfile`](../Dockerfile), [`.dockerignore`](../.dockerignore), [`compose.yaml`](../compose.yaml) ·
**Evidence:** [`evidence/04-docker-compose.txt`](../evidence/04-docker-compose.txt)

| Decision | Reason |
|---|---|
| `FROM python:3.12-slim` | A current, supported, small base image, with fewer packages and fewer vulnerabilities |
| Dedicated user `app`, **UID/GID 10001**, `USER 10001:10001` | A non-root process limits the damage if it's compromised. The numeric ID lets Kubernetes `runAsNonRoot` verify it. |
| `COPY app/` only | The image contains only what runs |
| `HEALTHCHECK` using Python `urllib` against `/healthz` | The slim image has no `curl`, and this avoids adding a package just for the check |
| `PYTHONUNBUFFERED=1` | Logs show up immediately in `docker logs` |
| `.dockerignore` excludes `.git`, tests, logs, Terraform files, evidence, generated env | A smaller build context, and no secrets or state leak into the image |

`compose.yaml` runs one service, `library-api`:
- `env_file: generated/service.env`: the Terraform output, as the task requires
- `ports: "127.0.0.1:8080:8080"`: reachable only from the local machine
- `read_only: true` with a `tmpfs` on `/tmp`, `cap_drop: [ALL]`, `no-new-privileges:true`: hardening

**Verified result:** status `(healthy)`, `id` gives `uid=10001(app)`, a write fails with
`Read-only file system`, `/healthz`, `/readyz`, `/info` and `/api/books` return 200 and `/unknown` returns 404.
Logs were captured, and `docker compose down` removed the container and the network.

## 5. Task 3: CI/CD with GitHub Actions

**File:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) ·
**Evidence:** [`evidence/06-ci-github-actions.txt`](../evidence/06-ci-github-actions.txt)

- **Triggers:** `push` and `pull_request`.
- **Permissions:** `contents: read` at both the workflow and job level. No secrets, no registry push.
- **Job `test`:** `python -m compileall -q app tests` (syntax check), then `python -m unittest discover -s tests -v`.
- **Job `docker-build`:** `needs: test`, so it **only runs when the tests pass**. It builds
  `campus-library:${{ github.sha }}` (a commit-derived tag), then runs a smoke test: it starts the container,
  calls the endpoints, and fails if the process runs as UID 0.

**Proof that a failing test blocks the build.** Branch `demo/failing-test` changes one assertion so
that it's wrong. In that run the unit-test step fails and the Docker build job is **skipped**. The branch
was never merged.

| Run | Result |
|---|---|
| [Healthy pipeline](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/actions/runs/45978577867) | tests ✅, then Docker build ✅ (tag `campus-library:5294d4a…`) |
| [Deliberately failing test](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/actions/runs/45978589020) | tests ❌, so Docker build is **skipped** |
| [All CI runs](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/actions/workflows/ci.yml) | every push and pull request |

## 6. Task 4: Kubernetes workload and rollout

**Files:** [`k8s/`](../k8s/) · **Evidence:** [`evidence/05-kubernetes-rollout.txt`](../evidence/05-kubernetes-rollout.txt) ·
**Run:** [Lab workflow run](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/actions/runs/45978582623)

| Manifest | Contents |
|---|---|
| [`namespace.yaml`](../k8s/namespace.yaml) | Namespace `devops-assessment` |
| [`configmap.yaml`](../k8s/configmap.yaml) | `APP_NAME`, `APP_ENV`, `LOG_LEVEL`, `PORT=8080`, `FAIL_MODE=0`, injected with `envFrom` |
| [`deployment.yaml`](../k8s/deployment.yaml) | 2 replicas · readiness `/readyz` · liveness `/healthz` · requests 50m/64Mi, limits 250m/128Mi · `runAsNonRoot`, UID 10001 · `readOnlyRootFilesystem` · drop ALL capabilities · no privilege escalation · seccomp `RuntimeDefault` · no service-account token · `RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1` |
| [`service.yaml`](../k8s/service.yaml) | ClusterIP Service, port 80 forwarding to targetPort 8080 |

**What was executed on a kind cluster** (Kubernetes v1.35):
1. Server-side dry run, then apply. The rollout finished with **2/2 Pods Ready**, running as `uid=10001`.
2. `kubectl port-forward svc/library-api 18080:80`. All endpoints returned 200.
3. **Healthy update** from image `1.0.0` to `1.0.1`, which rolled out successfully.
4. **Controlled bad release** with `FAIL_MODE=1`, then diagnosis, then `rollout undo`, then 2/2 Ready again (see section 8).
5. Cleanup by deleting the namespace.

`maxUnavailable: 0` is the key setting. During the bad release, Kubernetes added one new Pod but
kept both old Pods serving, so users saw no impact.

## 7. Task 5: Terraform configuration as code

**Files:** [`infra/`](../infra/) · **Evidence:** [`evidence/03-terraform.txt`](../evidence/03-terraform.txt)

- [`main.tf`](../infra/main.tf): a `hashicorp/local` `local_file` resource that writes `generated/service.env`.
- [`variables.tf`](../infra/variables.tf): typed inputs with validation:
  - `port`: a number, whole, **1024–65535**. Lower ports are privileged and a non-root container can't bind them.
  - `fail_mode`: 0 or 1. `app_env`: dev, test, staging or prod. `log_level`: DEBUG, INFO, WARNING or ERROR.
- [`dev.tfvars.example`](../infra/dev.tfvars.example): the development values. [`outputs.tf`](../infra/outputs.tf): the generated file's path.
- [`.terraform.lock.hcl`](../infra/.terraform.lock.hcl) is committed, with hashes for Linux, Windows and macOS, to pin the provider.

**Verified:** `fmt -check`, `init`, `validate`, `plan` and `apply` all succeeded, and the generated file had the 5 keys.
`plan -var=port=80` and `plan -var=fail_mode=2` were **rejected** with clear validation errors.

**Keeping state out of Git:** `*.tfstate`, `*.tfstate.*`, `.terraform/`, `*.tfvars` (except the
example) and `generated/service.env` are all in `.gitignore`. You can check with
`git check-ignore -v infra/terraform.tfstate`. A team setup would use a remote backend.

## 8. Task 6: Monitoring, security and recovery

**File:** [`docs/OPERATIONS.md`](OPERATIONS.md), which has the full detail.

**Error rate.** 2 of 24 requests are 5xx, so the rate is **8.33 %**. The 4 × 404 are client errors and
aren't counted as service failures.

**Proposed alert.** Page someone when the 5xx rate is **above 5 % over 5 minutes, with at least 20 requests** in the
window. Also open a low-priority ticket above 1 % over 30 minutes. The request minimum avoids paging on a
single error at low traffic. Health-check routes (13 of the 24 lines) should be measured separately from business traffic.

**Readiness vs liveness.** A readiness failure removes the Pod from the Service **without restarting it**.
A liveness failure **restarts** the container. This incident is a readiness failure.

**The bad release, as captured in `evidence/05`:**

| Step | Command | Observation |
|---|---|---|
| Trigger | `kubectl set env deployment/library-api FAIL_MODE=1` | a new revision, one new Pod |
| Detect | `kubectl rollout status --timeout=45s` | `timed out waiting for the condition` |
| Inspect | `kubectl get deploy,pods` | the Deployment still shows 2/2 available. The new Pod is `0/1 Running`, 0 restarts |
| Diagnose | `kubectl describe pod` | `Readiness probe failed: HTTP probe failed with statuscode: 503` |
| Confirm | `kubectl logs` | `/readyz` 503 while `/healthz` 200: the process is alive but not ready |
| Recover | `kubectl rollout undo deployment/library-api` | `rolled back` |
| Verify | `rollout status`, `get pods`, `curl /readyz` | `successfully rolled out`, 2/2 Ready, 200 |

**Security checks, each one demonstrated:**
- **Non-root:** UID 10001 in Docker and in Kubernetes, and CI fails if the UID is 0.
- **Read-only root filesystem:** a write attempt fails.
- **Capabilities and privilege:** all capabilities are dropped and privilege escalation is disabled.
- **No secrets or state in Git:** the whole history was scanned.
- **Least privilege in CI:** `contents: read`.
- **No network exposure:** Compose binds to `127.0.0.1`, and the Service is internal ClusterIP.

The incident runbook is in [`OPERATIONS.md` §6](OPERATIONS.md#6-incident-runbook-new-library-api-pods-never-become-ready).

## 9. Task 7: Documentation and evidence

- [`README.md`](../README.md): prerequisites and the exact commands for local setup, Terraform, Docker, CI, Kubernetes, rollback and cleanup.
- [`evidence/`](../evidence/): six files of real command output, indexed in [`evidence/README.txt`](../evidence/README.txt).
  Only ANSI colour codes and Docker build-progress lines were removed. Nothing was edited or invented.

---

## 10. How to verify everything in 5 minutes

**Without installing anything:**
1. Open the [Actions tab](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/actions) and look at the green CI runs on `main`, and the red run on `demo/failing-test` where the Docker build is skipped.
2. Open the [lab run](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/actions/runs/45978582623) and expand **Docker Compose lab** and **Kubernetes rollout lab** to see the full live output.
3. To run the lab again yourself, which needs a GitHub login with write access or a fork: go to **Actions → Lab evidence (manual) → Run workflow**.

**With Python 3.10+ only:**
```bash
git clone https://github.com/Hetansh-Pathak/DEVOPS_SET_D.git && cd DEVOPS_SET_D
python3 -m unittest discover -s tests -v          # 7 tests OK
bash scripts/analyze_logs.sh logs/access.log      # 24 / 4 / 2 / 8.33 %
python3 -m app.server & sleep 1
curl -s 'http://127.0.0.1:8080/api/books?code=BK-101'; kill %1
```

**With Docker, kind and Terraform:** `bash scripts/lab_docker.sh`, then `kind create cluster --name campus-lab`
and `KIND_CLUSTER=campus-lab bash scripts/lab_k8s.sh`. Both scripts print a transcript like the ones in `evidence/`.

## 11. Design decisions in question-and-answer form

**Why `needs: test` instead of a single job?** It makes the gate visible: a failed test shows the build job as *skipped*, which is exactly what the assessment asks me to demonstrate.

**Why tag images with the commit SHA?** Every image then traces back to the exact source that built it, which makes rollbacks and audits unambiguous. `latest` gives neither.

**Why `maxUnavailable: 0` and `maxSurge: 1`?** A release can't remove a healthy Pod until its replacement is Ready, so a misconfigured release fails safely instead of causing an outage.

**Why `imagePullPolicy: IfNotPresent`?** Images are loaded straight into kind (`kind load docker-image`), not pulled from a registry, which the assessment says not to use.

**Why these resource values?** The app is a tiny standard-library server. 50m CPU and 64Mi memory are enough to schedule it, and limits of 250m and 128Mi contain a runaway process. In production these would be tuned from metrics.

**Why a port range of 1024–65535?** 65535 is the highest TCP port. Ports below 1024 need root, and the container deliberately isn't root.

**Why commit `.terraform.lock.hcl` but not state?** The lock file pins provider versions for reproducible runs. State can contain sensitive data and belongs in a remote backend.

**Why bind Compose to `127.0.0.1`?** A development service shouldn't be reachable from other machines on the network.

## 12. Limitations and what I'd do next

- **Where Docker and Kubernetes ran.** My Windows workstation had no Docker Desktop or WSL2 (both need administrator rights). So the Docker Compose and kind labs ran on a GitHub-hosted Ubuntu runner through [`lab.yml`](../.github/workflows/lab.yml). The transcripts in `evidence/04` and `05` come from those runs. Log analysis, unit tests and Terraform ran locally.
- **Next steps for production:**
  - push images to a registry with signed tags
  - scan images (for example with Trivy) in CI
  - use a Terraform remote backend
  - add a PodDisruptionBudget, a NetworkPolicy and a HorizontalPodAutoscaler
  - export metrics to Prometheus so the proposed 5xx alert can be implemented as a real rule

**AI assistance.** I built this with help from an AI assistant (Claude), which the assessment permits when disclosed.
I reviewed every file and command, and I can explain each decision above.

## 13. Git history

| Commit | Purpose |
|---|---|
| `chore: add provided starter kit` | the original files, unchanged |
| `feat: add log analysis script and Linux evidence` | Task 1 |
| `feat(terraform): ...` | Task 5 |
| `feat(docker): ...` | Task 2 |
| `feat(ci,k8s): ...` | Tasks 3 and 4 |
| `feat(lab): ...` / `fix(lab): ...` | reproducible lab scripts and their fixes |
| `docs: ...` | README, operations runbook, evidence, this walkthrough |

You can see the full history in the [commit log](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/commits/main) and in pull requests [#1](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/pull/1) and [#2](https://github.com/Hetansh-Pathak/DEVOPS_SET_D/pull/2).
