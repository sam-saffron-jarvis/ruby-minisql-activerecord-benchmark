#!/usr/bin/env bash
set -euo pipefail

: "${PGUSER:=${USER:-postgres}}"
: "${BENCH_SECONDS:=15}"
: "${BENCH_WARMUP_SECONDS:=3}"
: "${USERS:=5000}"
: "${CATEGORIES:=32}"
: "${TOPICS:=50000}"
: "${AVG_POSTS:=6}"
: "${USE_EXISTING_DB:=0}"
: "${KEEP_DB:=0}"
: "${RESULTS_JSONL:=case-results.jsonl}"

CASES=(latest_page topic_header post_stream user_card category_counts temp_write_event temp_readback)
MODES=(mini_sql active_record sequel)
RUBIES=(3.4.6 4.0.5)
YJITS=(off on)
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

for v in "${RUBIES[@]}"; do
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
    PGDATABASE="ruby_case_bench_${USER:-user}_$(date +%Y%m%d%H%M%S)_$$"
  fi
  export PGDATABASE
  echo "== creating static benchmark database $PGDATABASE =="
  createdb "$PGDATABASE"
  DB_CREATED=1

  echo "== populating static benchmark database $PGDATABASE =="
  USERS="$USERS" CATEGORIES="$CATEGORIES" TOPICS="$TOPICS" AVG_POSTS="$AVG_POSTS" RESET=1 \
    mise x ruby@3.4.6 -- ruby setup-db.rb
fi

: > "$RESULTS_JSONL"

for v in "${RUBIES[@]}"; do
  echo "== ruby $v case matrix against $PGDATABASE =="
  for yjit in "${YJITS[@]}"; do
    if [ "$yjit" = "on" ]; then
      rubyopt="--yjit"
    else
      rubyopt=""
    fi
    for mode in "${MODES[@]}"; do
      for bench_case in "${CASES[@]}"; do
        echo "== ruby $v yjit $yjit $mode $bench_case case bench =="
        RUBYOPT="$rubyopt" BENCH_MODE="$mode" BENCH_CASE="$bench_case" BENCH_SECONDS="$BENCH_SECONDS" BENCH_WARMUP_SECONDS="$BENCH_WARMUP_SECONDS" PGDATABASE="$PGDATABASE" PGUSER="$PGUSER" \
          mise x ruby@$v -- ruby bench_cases_compare.rb | tee -a "$RESULTS_JSONL"
      done
    done
  done
done
