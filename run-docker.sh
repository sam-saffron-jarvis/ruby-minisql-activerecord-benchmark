#!/usr/bin/env bash
set -euo pipefail

: "${PGDATABASE:=ruby_data_bench}"
: "${PGUSER:=agent}"
: "${PGHOST:=bench-pg}"
: "${BENCH_SECONDS:=60}"
: "${USERS:=5000}"
: "${CATEGORIES:=32}"
: "${TOPICS:=50000}"
: "${AVG_POSTS:=6}"
: "${POSTGRES_IMAGE:=postgres:16}"
: "${NETWORK:=bench-net}"
: "${USE_EXISTING_DB:=0}"
: "${KEEP_DB:=0}"

DB_CREATED=0

cleanup() {
  if [ "$DB_CREATED" = "1" ] && [ "$KEEP_DB" != "1" ]; then
    echo "== removing benchmark postgres container $PGHOST and network $NETWORK =="
    docker rm -f "$PGHOST" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
  elif [ "$DB_CREATED" = "1" ]; then
    echo "== keeping benchmark postgres container $PGHOST on network $NETWORK =="
  fi
}
trap cleanup EXIT

if [ "$USE_EXISTING_DB" = "1" ]; then
  echo "== using existing static database $PGDATABASE on $PGHOST =="
else
  echo "== creating static postgres container $PGHOST =="
  docker network create "$NETWORK" 2>/dev/null || true
  docker rm -f "$PGHOST" 2>/dev/null || true
  docker run -d --name "$PGHOST" --network "$NETWORK" \
    -e POSTGRES_DB="$PGDATABASE" \
    -e POSTGRES_USER="$PGUSER" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    "$POSTGRES_IMAGE" >/dev/null
  DB_CREATED=1

  for _ in $(seq 1 60); do
    if docker exec "$PGHOST" pg_isready -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "== populating static benchmark database $PGDATABASE in $PGHOST =="
  docker run --rm --network "$NETWORK" \
    -v "$PWD:/bench" -w /bench \
    -e PGDATABASE="$PGDATABASE" \
    -e PGUSER="$PGUSER" \
    -e PGHOST="$PGHOST" \
    -e USERS="$USERS" \
    -e CATEGORIES="$CATEGORIES" \
    -e TOPICS="$TOPICS" \
    -e AVG_POSTS="$AVG_POSTS" \
    -e RESET=1 \
    ruby:3.4.6 bash -lc 'gem install pg --no-document >/dev/null; ruby setup-db.rb'
fi

for v in 3.4.6 4.0.5; do
  image="ruby:${v}"
  echo "== pulling $image =="
  docker pull "$image" >/dev/null
  for yjit in off on; do
    if [ "$yjit" = "on" ]; then
      rubyopt="--yjit"
    else
      rubyopt=""
    fi
    for mode in mini_sql active_record sequel; do
      echo "== docker $image yjit $yjit $mode story bench =="
      docker run --rm --network "$NETWORK" \
        -v "$PWD:/bench" -w /bench \
        -e BENCH_SECONDS="$BENCH_SECONDS" \
        -e BENCH_MODE="$mode" \
        -e PGDATABASE="$PGDATABASE" \
        -e PGUSER="$PGUSER" \
        -e PGHOST="$PGHOST" \
        -e RUBYOPT="$rubyopt" \
        "$image" bash -lc 'ruby -v; ruby -e "p(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?)"; gem install mini_sql pg activerecord sequel --no-document >/dev/null; ruby bench_story_compare.rb'
    done
  done
done
