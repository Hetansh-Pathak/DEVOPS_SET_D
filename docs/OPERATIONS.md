# Operations: monitoring, security and incident runbook

## 1. Log metrics from `logs/access.log`

Commands, executed in `evidence/01-linux-log-analysis.txt`:

```bash
wc -l < logs/access.log                                           # 24 total
awk '$2 ~ /^4/' logs/access.log | wc -l                           # 4  (all 404 /unknown)
awk '$2 ~ /^5/' logs/access.log | wc -l                           # 2  (503 /readyz, 503 /api/books)
awk '{print $4}' logs/access.log | sort | uniq -c | sort -rn | head -3
bash scripts/analyze_logs.sh logs/access.log
```

| Metric | Value |
|---|---|
| Total requests | 24 |
| HTTP 2xx | 18 |
| HTTP 4xx | 4 |
| HTTP 5xx | 2 |
| **HTTP 5xx rate** | **2 / 24 = 8.33 %** |
| Top routes | `/healthz` 8, `/api/books?code=BK-101` 6, `/readyz` 5 |

The 4xx count is `/unknown` returning 404. That's a client error, not a server
fault, so it doesn't count toward the error budget.

## 2. Proposed alert

**Alert `LibraryApi5xxRateHigh`: page when the 5xx rate is above 5 % over 5 minutes
and there were at least 20 requests in that window.**

- 5 % is well above normal for an internal lookup API, which should be close to 0 %.
  The fixture's 8.33 % would fire it, and it should. The two 503s happened
  next to each other at 09:02:12 and 09:02:18, right after the server stopped being ready.
- The minimum of 20 requests stops a single 503 at low traffic from paging someone
  (1 failure out of 2 requests is 50 %).
- Add a lower-priority ticket alert at above 1 % over 30 minutes to catch slow drift.
- Count health-check traffic (`/healthz` and `/readyz`) separately from business
  traffic (`/api/*`). It's a third of this log and would hide real user errors.

## 3. Readiness failure vs liveness failure

| | Readiness (`/readyz`) | Liveness (`/healthz`) |
|---|---|---|
| Question asked | Can this Pod serve traffic right now? | Is the process still alive or stuck? |
| On failure, Kubernetes | Removes the Pod from Service endpoints. **No restart.** | **Kills and restarts** the container. |
| What you see | `READY 0/1`, `STATUS Running`, `RESTARTS 0`, events say `Readiness probe failed: ... 503` | `RESTARTS` goes up, events say `Liveness probe failed`, may reach `CrashLoopBackOff` |
| In this incident | Yes. `FAIL_MODE=1` makes `/readyz` return 503 | No. `/healthz` kept returning 200 (see the Pod log) |
| Fix | Fix the config or roll back. Restarting doesn't help. | Find out why the process hangs or crashes |

So the controlled incident is a **readiness** failure. The Pod is running and was
never restarted, but it never becomes Ready.

## 4. Controlled bad rollout: diagnosis and recovery (executed in `evidence/05-kubernetes-rollout.txt`)

The Deployment uses `maxUnavailable: 0, maxSurge: 1`. A bad release can only add
**one** extra Pod, and the two healthy Pods stay up and serving the whole time.

**Trigger**
```bash
kubectl -n devops-assessment set env deployment/library-api FAIL_MODE=1
```

**Detect**
```bash
kubectl -n devops-assessment rollout status deployment/library-api --timeout=45s
#  -> error: timed out waiting for the condition  (exit 1)
kubectl -n devops-assessment get deploy,pods -o wide
#  -> deployment 2/2 READY, UP-TO-DATE 1; new pod READY 0/1, STATUS Running, RESTARTS 0
```

**Diagnose**
```bash
kubectl -n devops-assessment describe pod <new-pod>
#  -> Ready: False ; Warning Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 503
kubectl -n devops-assessment logs <new-pod> --tail=15
#  -> "GET /readyz" 503   and   "GET /healthz" 200   (liveness fine, readiness failing)
kubectl -n devops-assessment get events --sort-by=.lastTimestamp
kubectl -n devops-assessment rollout history deployment/library-api
```
Root cause: the latest revision added `FAIL_MODE=1` to the Pod environment, and
the app then returns 503 on `/readyz`.

**Recover**
```bash
kubectl -n devops-assessment rollout undo deployment/library-api
kubectl -n devops-assessment rollout status deployment/library-api --timeout=120s   # successfully rolled out
kubectl -n devops-assessment get deploy,pods                                         # 2/2 Ready, bad pod Terminating
kubectl -n devops-assessment get deployment library-api \
  -o jsonpath='{.spec.template.spec.containers[0].env}'                              # empty -> FAIL_MODE override gone
kubectl -n devops-assessment port-forward svc/library-api 18080:80 &
curl -i http://127.0.0.1:18080/readyz                                                # 200 {"status": "ready"}
```

## 5. Security checks (each one verified)

| # | Check | How it's enforced | Evidence |
|---|---|---|---|
| 1 | **Runs as non-root** | Dockerfile `USER 10001:10001`. Pod `runAsNonRoot: true`, `runAsUser: 10001` | `id` -> `uid=10001(app)` in both `04-docker-compose.txt` and `05-kubernetes-rollout.txt`. CI smoke test fails if the UID is 0. |
| 2 | **Read-only root filesystem, no extra privileges** | Compose `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`. K8s `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false` | `touch /srv/x` -> `Read-only file system` (`04-docker-compose.txt`) |
| 3 | **No secrets or state in Git** | `.gitignore` covers `*.tfstate*`, `.terraform/`, `generated/service.env`, `.env`. `.dockerignore` keeps them out of the image too. | `git ls-files \| grep -E 'tfstate\|\.terraform/\|service\.env'` -> nothing |
| 4 | **Minimal CI permissions** | `permissions: contents: read` at workflow and job level. No registry push, no secrets used. | `.github/workflows/ci.yml` |

## 6. Incident runbook: "new library-api Pods never become Ready"

1. **Confirm impact.** Run `kubectl -n devops-assessment get deploy,pods`. If the old
   ReplicaSet still shows `2/2` available, users aren't affected (thanks to `maxUnavailable: 0`).
   Stop any further rollouts.
2. **Readiness or liveness?** Check `kubectl describe pod <new-pod>`. Readiness 503
   with `RESTARTS 0` is a config or dependency problem. If restarts are climbing, see the liveness row in section 3.
3. **Find what changed.** Run `kubectl rollout history deployment/library-api --revision=<n>`
   and compare the env, image and ConfigMap with the previous revision. Read `kubectl logs <new-pod>`.
4. **Recover first, investigate after.** Run `kubectl rollout undo deployment/library-api`,
   then `kubectl rollout status` until 2/2 are Ready.
5. **Verify.** Port-forward and `curl /readyz` and `/api/books?code=BK-101` -> 200.
   Confirm the 5xx rate is back under the alert threshold.
6. **Follow up.** Fix the config in Git (ConfigMap or Terraform vars), never with
   a manual edit on the cluster. Add a test or CI check, and write a short incident note.
