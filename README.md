# Campus Library Book Lookup API: DevOps assessment (Set D)

This repo takes the provided Python HTTP service through local, container, CI and
Kubernetes deployment, with Terraform-generated configuration. The application
code in `app/` and the tests in `tests/` are the **unchanged starter kit**.

| Task | Where | Evidence |
|---|---|---|
| 1. Linux, Git | `scripts/analyze_logs.sh`, branch `feature/devops-assessment` | `evidence/01-linux-log-analysis.txt` |
| 2. Docker, Compose | `Dockerfile`, `.dockerignore`, `compose.yaml` | `evidence/04-docker-compose.txt` |
| 3. CI/CD | `.github/workflows/ci.yml` | `evidence/02-local-tests.txt`, `evidence/06-ci-github-actions.txt` |
| 4. Kubernetes | `k8s/*.yaml` | `evidence/05-kubernetes-rollout.txt` |
| 5. Terraform | `infra/*.tf`, `infra/dev.tfvars.example` | `evidence/03-terraform.txt` |
| 6. Monitoring, security, recovery | `docs/OPERATIONS.md` | `evidence/01`, `04`, `05` |
| 7. README and evidence | this file, `evidence/` | see "What was verified where" below |

## Prerequisites

Linux, WSL2 or macOS with: Git, Python 3.10+ (3.12 used), Docker with the Compose plugin,
Terraform 1.5+, kubectl, and kind (or minikube). No cloud account or registry is needed.

## 1. Local run and tests

```bash
python3 -m compileall -q app tests
python3 -m unittest discover -s tests -v
PORT=8080 python3 -m app.server &
curl -i http://127.0.0.1:8080/healthz
curl -i 'http://127.0.0.1:8080/api/books?code=BK-101'
kill %1
```

Log analysis:
```bash
bash scripts/analyze_logs.sh logs/access.log      # exit 0, prints counts
bash scripts/analyze_logs.sh missing.log; echo $? # exit 1, missing file
```

## 2. Terraform: generate `generated/service.env`

```bash
cd infra
cp dev.tfvars.example dev.tfvars        # optional local copy (dev.tfvars stays untracked)
terraform fmt -check -recursive
terraform init
terraform validate
terraform plan  -var-file=dev.tfvars.example
terraform apply -var-file=dev.tfvars.example
cat ../generated/service.env
cd ..
```

Inputs are typed and validated: `port` must be a whole number from 1024 to 65535,
`fail_mode` must be 0 or 1, and `app_env` and `log_level` must come from fixed lists.
`terraform plan -var=port=80` is rejected (shown in the evidence).

**Keeping state and generated files out of Git.** `.gitignore` lists `*.tfstate`,
`*.tfstate.*`, `.terraform/`, `generated/service.env` and `.env`. Check with
`git status --ignored` or `git check-ignore -v infra/terraform.tfstate`. Only
`.terraform.lock.hcl` is committed, which is intended because it pins provider versions.
In a team you'd also use a remote backend, so no state file ever sits in the working copy.

## 3. Docker and Compose

Run Terraform first (step 2). Compose reads `generated/service.env`.

```bash
docker compose up --build -d
docker compose ps                                   # STATUS shows (healthy)
curl -i http://127.0.0.1:8080/healthz               # 200
curl -i http://127.0.0.1:8080/readyz                # 200
curl -i 'http://127.0.0.1:8080/api/books?code=BK-101'
docker exec campus-library-api id                   # uid=10001(app)
docker compose logs --tail 20
docker compose down --remove-orphans
```

To run everything above in one go and capture a transcript: `bash scripts/lab_docker.sh`.

## 4. CI (GitHub Actions)

`.github/workflows/ci.yml` runs on every `push` and `pull_request` with `permissions: contents: read`.

1. **test** job: `python -m compileall` (syntax check), then `python -m unittest discover -s tests -v`.
2. **docker-build** job (`needs: test`): builds `campus-library:${{ github.sha }}`, then smoke-tests
   `/healthz`, `/readyz`, the books endpoint and the non-root UID. Nothing is pushed.

If a test fails, the Docker build is skipped. Branch `demo/failing-test` proves this
(see `evidence/06-ci-github-actions.txt`).

## 5. Kubernetes (kind)

```bash
kind create cluster --name campus-lab
docker build -t campus-library:1.0.0 .
docker tag campus-library:1.0.0 campus-library:1.0.1
kind load docker-image campus-library:1.0.0 campus-library:1.0.1 --name campus-lab

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml -f k8s/deployment.yaml -f k8s/service.yaml
kubectl -n devops-assessment rollout status deployment/library-api
kubectl -n devops-assessment get deploy,pods,svc        # 2/2 Ready, ClusterIP 80/TCP

kubectl -n devops-assessment port-forward svc/library-api 18080:80 &
curl -i http://127.0.0.1:18080/readyz
curl -i 'http://127.0.0.1:18080/api/books?code=BK-101'
```

The manifests give you a `devops-assessment` namespace, a ConfigMap, a Deployment
with 2 replicas, and a ClusterIP Service that maps port 80 to 8080. Readiness checks
`/readyz` and liveness checks `/healthz`. Each Pod requests 50m CPU and 64Mi memory,
with limits of 250m CPU and 128Mi memory. Pods run as non-root with a read-only root
filesystem and all capabilities dropped. The rollout uses `maxUnavailable: 0` and `maxSurge: 1`.

### Healthy update, controlled incident and rollback

```bash
# healthy update
kubectl -n devops-assessment set image deployment/library-api library-api=campus-library:1.0.1
kubectl -n devops-assessment rollout status deployment/library-api

# controlled bad release (lab only)
kubectl -n devops-assessment set env deployment/library-api FAIL_MODE=1
kubectl -n devops-assessment rollout status deployment/library-api --timeout=45s   # times out
kubectl -n devops-assessment get pods                                              # new pod 0/1
kubectl -n devops-assessment describe pod <new-pod>                                # Readiness probe failed: 503
kubectl -n devops-assessment logs <new-pod>
kubectl -n devops-assessment get events --sort-by=.lastTimestamp

# rollback and verify
kubectl -n devops-assessment rollout undo deployment/library-api
kubectl -n devops-assessment rollout status deployment/library-api
curl -i http://127.0.0.1:18080/readyz                                              # 200
```

`bash scripts/lab_k8s.sh` runs this whole sequence. The diagnosis, the alert threshold,
the readiness-vs-liveness comparison, the security checks and the runbook are in
**[docs/OPERATIONS.md](docs/OPERATIONS.md)**.

## 6. Cleanup

```bash
kubectl delete namespace devops-assessment
kind delete cluster --name campus-lab
docker compose down --remove-orphans
docker image rm campus-library:local campus-library:1.0.0 campus-library:1.0.1
cd infra && terraform destroy -var-file=dev.tfvars.example     # removes generated/service.env
```

## What was verified where (honest statement)

| Step | Executed? | Where |
|---|---|---|
| Log analysis and `analyze_logs.sh` | Yes | Candidate's Windows PC (Git Bash) |
| Syntax check and unit tests, live endpoint check | Yes | Candidate's PC (Python 3.12) |
| `terraform fmt / init / validate / plan / apply`, port validation | Yes | Candidate's PC (Terraform 1.17.2) |
| CI healthy run, failing-test gate, commit-SHA tag | Yes | GitHub Actions (links in `evidence/06`) |
| Docker build, Compose, health, non-root, logs, teardown | Yes, **on a GitHub-hosted Ubuntu runner** | Workflow `lab.yml`, `evidence/04` |
| kind deploy, port-forward, update, FAIL_MODE incident, rollout undo | Yes, **on a GitHub-hosted Ubuntu runner** | Workflow `lab.yml`, `evidence/05` |
| Docker and kind on the candidate's own PC | **No.** Docker Desktop and WSL2 weren't installed and need admin rights and a reboot. | n/a |
| minikube | Not used (kind instead) | n/a |

All evidence files are real command output. Only ANSI colour codes and BuildKit
progress lines were removed. No passwords or tokens appear in them.

## AI assistance disclosure

These files were written with help from Claude (an AI assistant). The commands
were run, and their output checked, as described above. The starter `app/` and
`tests/` were not changed.
