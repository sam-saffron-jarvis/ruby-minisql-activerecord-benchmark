#!/usr/bin/env bash
set -euo pipefail

: "${PGDATABASE:=discourse_sql_ft}"
: "${PGUSER:=agent}"
: "${POSTGRES_IMAGE:=postgres:16}"
: "${BENCH_SECONDS:=60}"
: "${USERS:=5000}"
: "${CATEGORIES:=32}"
: "${TOPICS:=50000}"
: "${AVG_POSTS:=6}"

NETWORK=${NETWORK:-bench-net}
CONTAINER=${CONTAINER:-bench-pg}

docker network create "$NETWORK" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

docker run -d --name "$CONTAINER" --network "$NETWORK" \
  -e POSTGRES_DB="$PGDATABASE" \
  -e POSTGRES_USER="$PGUSER" \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  "$POSTGRES_IMAGE"

for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" pg_isready -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker run --rm --network "$NETWORK" \
  -v "$PWD:/bench" -w /bench \
  -e PGDATABASE="$PGDATABASE" \
  -e PGUSER="$PGUSER" \
  -e PGHOST="$CONTAINER" \
  -e USERS="$USERS" \
  -e CATEGORIES="$CATEGORIES" \
  -e TOPICS="$TOPICS" \
  -e AVG_POSTS="$AVG_POSTS" \
  -e RESET=1 \
  ruby:3.4.6 bash -lc 'gem install pg --no-document >/dev/null; ruby setup-db.rb'

cat <<EOF

PostgreSQL benchmark container is ready.

Run benchmark with:

  PGDATABASE=$PGDATABASE PGUSER=$PGUSER PGHOST=$CONTAINER BENCH_SECONDS=$BENCH_SECONDS ./run-docker.sh

Cleanup:

  docker rm -f $CONTAINER
  docker network rm $NETWORK
EOF
