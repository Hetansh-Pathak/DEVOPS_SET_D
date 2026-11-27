#!/usr/bin/env bash
# Task 2 lab: Terraform -> generated/service.env -> docker compose up/health/logs/down.
# Requires: terraform, docker with compose plugin, curl. Run from anywhere.
set -uo pipefail
cd "$(dirname "$0")/.."
export TF_CLI_ARGS="-no-color"   # keep transcripts free of ANSI colour codes

run() { echo; echo "\$ $*"; "$@" 2>&1; echo "exit=$?"; }
show() { echo; echo "\$ curl -si $1 | head -1; curl -s $1"; curl -si "$1" | head -1; curl -s "$1"; echo; }

echo "# Task 2 - Docker + Compose evidence ($(date -u +%FT%TZ))"
run terraform -chdir=infra init -input=false
run terraform -chdir=infra apply -input=false -auto-approve -var-file=dev.tfvars.example
run cat generated/service.env

run docker compose up --build -d

echo; echo "# waiting for container health"
for i in $(seq 1 30); do
  s=$(docker inspect --format '{{.State.Health.Status}}' campus-library-api 2>/dev/null || echo starting)
  [ "$s" = "healthy" ] && break; sleep 2
done
run docker compose ps
echo; echo "\$ docker inspect health status: $(docker inspect --format '{{.State.Health.Status}}' campus-library-api)"
run docker exec campus-library-api id
run docker exec campus-library-api sh -c 'touch /srv/x 2>&1 || echo "root filesystem is read-only (expected)"'

show http://127.0.0.1:8080/healthz
show http://127.0.0.1:8080/readyz
show http://127.0.0.1:8080/info
show "http://127.0.0.1:8080/api/books?code=BK-101"
show http://127.0.0.1:8080/unknown

run docker compose logs --no-color --tail 20
run docker compose down --remove-orphans
run docker compose ps -a
