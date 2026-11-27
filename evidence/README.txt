Evidence index (real, sanitized command output - no passwords/tokens)

01-linux-log-analysis.txt  Task 1  awk/wc commands + scripts/analyze_logs.sh (ok, missing file, no args)   [run locally]
02-local-tests.txt         Task 3  python compileall + unittest, 7/7 pass                                   [run locally]
03-terraform.txt           Task 5  fmt, init, validate, plan, apply, generated env, validation rejections   [run locally]
04-docker-compose.txt      Task 2  compose build/up, healthy, uid 10001, read-only fs, endpoints, logs, down [GitHub runner]
05-kubernetes-rollout.txt  Task 4/6 kind deploy, port-forward, update, FAIL_MODE=1 incident, undo, cleanup   [GitHub runner]
06-ci-github-actions.txt   Task 3  healthy CI run + failing test skipping Docker build, commit-SHA tag      [GitHub Actions]

Docker and kind were NOT run on the candidate's Windows PC (no Docker Desktop/WSL2);
they were executed by .github/workflows/lab.yml on ubuntu-latest. See README "What was verified where".
