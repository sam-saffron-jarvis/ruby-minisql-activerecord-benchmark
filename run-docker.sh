#!/usr/bin/env bash
set -euo pipefail

: "${PGDATABASE:=discourse_sql_ft}"
: "${PGUSER:=agent}"
: "${PGHOST:=bench-pg}"
: "${BENCH_SECONDS:=60}"

for v in 3.4.6 4.0.5; do
  image="ruby:${v}"
  echo "== pulling $image =="
  docker pull "$image"
  for mode in mini_sql active_record; do
    echo "== docker $image $mode story bench =="
    docker run --rm --network bench-net \
      -v "$PWD:/bench" -w /bench \
      -e BENCH_SECONDS="$BENCH_SECONDS" \
      -e BENCH_MODE="$mode" \
      -e PGDATABASE="$PGDATABASE" \
      -e PGUSER="$PGUSER" \
      -e PGHOST="$PGHOST" \
      "$image" bash -lc 'ruby -v; gem install mini_sql pg activerecord --no-document >/dev/null; ruby bench_story_compare.rb'
  done
done
