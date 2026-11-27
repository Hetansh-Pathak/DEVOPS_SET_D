#!/usr/bin/env bash
# Task 4/6 lab: deploy to kind, healthy update, controlled FAIL_MODE=1 rollout, diagnose, undo.
# Requires: docker, kind (cluster already created, name in $KIND_CLUSTER), kubectl, curl.
set -uo pipefail
cd "$(dirname "$0")/.."
NS=devops-assessment
KIND_CLUSTER="${KIND_CLUSTER:-campus-lab}"

run() { echo; echo "\$ $*"; "$@" 2>&1; echo "exit=$?"; }
pf_check() {  # port-forward the Service and probe an endpoint
  kubectl -n "$NS" port-forward svc/library-api 18080:80 >/dev/null 2>&1 & local pid=$!
  sleep 3
  for p in healthz readyz info "api/books?code=BK-101"; do
    echo; echo "\$ curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/$p  ->  $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18080/$p")"
    curl -s "http://127.0.0.1:18080/$p"; echo
  done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
}

echo "# Task 4/6 - Kubernetes rollout evidence ($(date -u +%FT%TZ))"
run kubectl version
run kubectl get nodes

echo; echo "## 1. Build images and load into kind"
run docker build -t campus-library:1.0.0 .
run docker tag campus-library:1.0.0 campus-library:1.0.1
run kind load docker-image campus-library:1.0.0 campus-library:1.0.1 --name "$KIND_CLUSTER"

echo; echo "## 2. Static validation against the API server, then deploy"
run kubectl apply -f k8s/namespace.yaml
run kubectl apply --dry-run=server -f k8s/configmap.yaml -f k8s/deployment.yaml -f k8s/service.yaml
run kubectl apply -f k8s/configmap.yaml -f k8s/deployment.yaml -f k8s/service.yaml
run kubectl -n "$NS" rollout status deployment/library-api --timeout=120s
run kubectl -n "$NS" get deploy,pods,svc -o wide
echo; echo "\$ pod user check"
POD=$(kubectl -n "$NS" get pods -l app=library-api -o jsonpath='{.items[0].metadata.name}')
run kubectl -n "$NS" exec "$POD" -- id

echo; echo "## 3. Access through kubectl port-forward"
pf_check

echo; echo "## 4. Healthy update 1.0.0 -> 1.0.1"
run kubectl -n "$NS" set image deployment/library-api library-api=campus-library:1.0.1
run kubectl -n "$NS" rollout status deployment/library-api --timeout=120s
run kubectl -n "$NS" get pods -o wide
run kubectl -n "$NS" rollout history deployment/library-api

echo; echo "## 5. Controlled incident: FAIL_MODE=1 rollout (readiness must fail)"
run kubectl -n "$NS" set env deployment/library-api FAIL_MODE=1
run kubectl -n "$NS" rollout status deployment/library-api --timeout=45s
echo "(non-zero exit above is EXPECTED: the new Pod never becomes Ready)"
run kubectl -n "$NS" get deploy,pods -o wide
BAD=$(kubectl -n "$NS" get pods -l app=library-api --sort-by=.metadata.creationTimestamp -o name | tail -1)
echo "bad pod: $BAD"
run kubectl -n "$NS" describe "$BAD"
run kubectl -n "$NS" logs "$BAD" --tail=15
run kubectl -n "$NS" get events --sort-by=.lastTimestamp

echo; echo "## 6. Recovery: rollout undo + verification"
run kubectl -n "$NS" rollout undo deployment/library-api
run kubectl -n "$NS" rollout status deployment/library-api --timeout=120s
run kubectl -n "$NS" get deploy,pods -o wide
run kubectl -n "$NS" get deployment library-api -o jsonpath='{.spec.template.spec.containers[0].env}'
echo; pf_check

echo; echo "## 7. Cleanup"
run kubectl delete namespace "$NS" --wait=true
