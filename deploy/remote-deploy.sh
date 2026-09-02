#!/usr/bin/env bash
# The deploy, as a script — the same sequence the runbook prescribes by hand:
# build the new image, migrate on it while the old container keeps serving,
# then swap and prove the app answers.
set -euo pipefail

cd /apps/cold-forge
git pull --ff-only
cd deploy

echo "== building image =="
docker compose build --quiet

# Explicit, not at boot. A one-off container on the NEW image, so a migration
# that fails takes down the deploy rather than the running app.
echo "== running migrations (one-off on the new image) =="
docker compose run --rm app /app/bin/cold_forge eval "ColdForge.Release.migrate"

echo "== swapping container =="
docker compose up -d

echo "== waiting for the app to answer =="
live=""
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null http://127.0.0.1:4010; then
    live=yes
    break
  fi
  sleep 2
done

if [ -z "$live" ]; then
  echo "== FAILED: app did not answer on 127.0.0.1:4010 after 60s =="
  docker logs cold_forge --since 2m | tail -50
  exit 1
fi

echo "== deployed: $(git -C /apps/cold-forge rev-parse --short HEAD) is live =="
