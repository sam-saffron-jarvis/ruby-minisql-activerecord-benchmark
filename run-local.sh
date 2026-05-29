#!/usr/bin/env bash
set -euo pipefail

: "${PGDATABASE:=discourse_sql_ft}"
: "${PGUSER:=agent}"
: "${BENCH_SECONDS:=60}"

for v in 3.4.6 4.0.5; do
  echo "== ruby $v setup =="
  mise x ruby@$v -- ruby -v
  mise x ruby@$v -- gem install mini_sql pg activerecord --no-document >/dev/null
  for mode in mini_sql active_record; do
    echo "== ruby $v $mode story bench =="
    BENCH_MODE=$mode BENCH_SECONDS=$BENCH_SECONDS PGDATABASE=$PGDATABASE PGUSER=$PGUSER \
      mise x ruby@$v -- ruby bench_story_compare.rb
  done
done
