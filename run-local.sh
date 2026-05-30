#!/usr/bin/env bash
set -euo pipefail

: "${PGUSER:=${USER:-postgres}}"
: "${BENCH_SECONDS:=60}"
: "${USERS:=5000}"
: "${CATEGORIES:=32}"
: "${TOPICS:=50000}"
: "${AVG_POSTS:=6}"
: "${USE_EXISTING_DB:=0}"
: "${KEEP_DB:=0}"

DB_CREATED=0
ORIGINAL_PGDATABASE="${PGDATABASE:-}"

cleanup() {
  if [ "$DB_CREATED" = "1" ] && [ "$KEEP_DB" != "1" ]; then
    echo "== dropping benchmark database $PGDATABASE =="
    dropdb "$PGDATABASE" >/dev/null 2>&1 || true
  elif [ "$DB_CREATED" = "1" ]; then
    echo "== keeping benchmark database $PGDATABASE =="
  fi
}
trap cleanup EXIT

for v in 3.4.6 4.0.5; do
  echo "== ruby $v gem setup =="
  mise x ruby@$v -- ruby -v
  mise x ruby@$v -- gem install mini_sql pg activerecord sequel --no-document >/dev/null
done

if [ "$USE_EXISTING_DB" = "1" ]; then
  : "${PGDATABASE:?PGDATABASE is required when USE_EXISTING_DB=1}"
  echo "== using existing static database $PGDATABASE =="
else
  if [ -n "$ORIGINAL_PGDATABASE" ]; then
    PGDATABASE="$ORIGINAL_PGDATABASE"
  else
    PGDATABASE="ruby_data_bench_${USER:-user}_$(date +%Y%m%d%H%M%S)_$$"
  fi
  export PGDATABASE
  echo "== creating static benchmark database $PGDATABASE =="
  createdb "$PGDATABASE"
  DB_CREATED=1

  echo "== populating static benchmark database $PGDATABASE =="
  USERS="$USERS" CATEGORIES="$CATEGORIES" TOPICS="$TOPICS" AVG_POSTS="$AVG_POSTS" RESET=1 \
    mise x ruby@3.4.6 -- ruby setup-db.rb
fi

for v in 3.4.6 4.0.5; do
  echo "== ruby $v benchmark matrix against $PGDATABASE =="
  for yjit in off on; do
    if [ "$yjit" = "on" ]; then
      rubyopt="--yjit"
    else
      rubyopt=""
    fi
    for mode in mini_sql active_record sequel; do
      echo "== ruby $v yjit $yjit $mode story bench =="
      RUBYOPT="$rubyopt" BENCH_MODE=$mode BENCH_SECONDS=$BENCH_SECONDS PGDATABASE=$PGDATABASE PGUSER=$PGUSER \
        mise x ruby@$v -- ruby bench_story_compare.rb
    done
  done
done
