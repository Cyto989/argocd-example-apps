#!/usr/bin/env bash
set -uo pipefail

NS=cicd
APP=guestbook
CHART_DIR=helm-guestbook3
COUNT=15
LOGFILE="/tmp/repo-server-$(date +%s).log"

echo "==> Making a trivial commit to force a brand-new, never-cached revision"
cd "$(git rev-parse --show-toplevel)" || exit 1
cd "$CHART_DIR" || { echo "Run this from inside or above $CHART_DIR"; exit 1; }
echo "# race-test-$(date +%s)" >> values.yaml
git add values.yaml
git commit -m "race test trigger $(date +%s)"
git push
SHA=$(git rev-parse HEAD)
echo "    new revision: $SHA"
cd - >/dev/null

echo "==> Logging repo-server"
kubectl logs -n "$NS" -l app.kubernetes.io/name=argocd-repo-server -f --tail=0 > "$LOGFILE" 2>&1 &
LOG_PID=$!
sleep 2

echo "==> Firing $COUNT concurrent manifest renders against revision $SHA (read-only, nothing applied)"
PIDS=()
for i in $(seq 1 "$COUNT"); do
  argocd app manifests "$APP" --revision "$SHA" >/dev/null 2>&1 &
  PIDS+=($!)
done

echo "==> Waiting for all $COUNT render calls to finish"
for pid in "${PIDS[@]}"; do
  wait "$pid"
done

echo "==> All renders done, waiting 5s more for log flush"
sleep 5

kill "$LOG_PID" 2>/dev/null
wait "$LOG_PID" 2>/dev/null

echo "==> Checking for the race..."
if grep -q "tmpcharts" "$LOGFILE"; then
  echo "✅ REPRODUCED. Context:"
  grep -B10 -A10 "tmpcharts" "$LOGFILE"
else
  echo "❌ Not reproduced this run. Log saved at $LOGFILE — rerun the whole script again."
fi
