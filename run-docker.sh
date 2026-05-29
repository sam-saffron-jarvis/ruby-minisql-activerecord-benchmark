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
  for yjit in off on; do
    if [ "$yjit" = "on" ]; then
      rubyopt="--yjit"
    else
      rubyopt=""
    fi
    for mode in mini_sql active_record; do
      echo "== docker $image yjit $yjit $mode story bench =="
      docker run --rm --network bench-net \
        -v "$PWD:/bench" -w /bench \
        -e BENCH_SECONDS="$BENCH_SECONDS" \
        -e BENCH_MODE="$mode" \
        -e PGDATABASE="$PGDATABASE" \
        -e PGUSER="$PGUSER" \
        -e PGHOST="$PGHOST" \
        -e RUBYOPT="$rubyopt" \
        "$image" bash -lc 'ruby -v; ruby -e "p(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?)"; gem install mini_sql pg activerecord --no-document >/dev/null; ruby bench_story_compare.rb'
    done
  done
done
