# Ruby data-access benchmark: MiniSql, ActiveRecord, Sequel

A reproducible benchmark for Ruby PostgreSQL data access on a Discourse-ish workload.

Article: https://wasnotwas.com/writing/minisql-activerecord-and-ruby-4-a-small-benchmark-with-a-pulse/

## What it measures

This is **not** a full Rails request benchmark. It compares the query/data-access layer for a forum-style workload:

1. Latest topic list
2. Topic header
3. Post stream
4. User card aggregate
5. Category dashboard aggregate
6. Temporary autosave/event write
7. Temporary readback count

Every query result is iterated and converted into tab-separated text. The benchmark records row counts and rendered byte counts so it measures data access plus lightweight serialization, not just `.length` on an already-materialized array.

The matrix supports:

- Ruby 3.4.6 and Ruby 4.0.5
- YJIT off and on (`RUBYOPT=--yjit`)
- MiniSql
- ActiveRecord
- Sequel

## Database setup

Use `setup-db.rb` to create a synthetic Discourse-like dataset with the tables and indexes the benchmark expects.

Default dataset:

- 5,000 users
- 32 categories
- 50,000 topics
- roughly 300,000 posts (`AVG_POSTS=6`)
- indexes for the benchmark queries

```bash
createdb minisql_ar_bench
mise x ruby@3.4.6 -- gem install pg --no-document
PGDATABASE=minisql_ar_bench PGUSER=$USER ruby setup-db.rb
```

Tune the dataset size:

```bash
USERS=10000 CATEGORIES=48 TOPICS=100000 AVG_POSTS=8 \
  PGDATABASE=minisql_ar_bench PGUSER=$USER ruby setup-db.rb
```

The setup script is deterministic by default (`SEED=20260529`) and resets the benchmark tables unless `RESET=0` is set.

## Local run with mise

```bash
mise install ruby@3.4.6 ruby@4.0.5
export PGDATABASE=minisql_ar_bench
export PGUSER=$USER
export BENCH_SECONDS=60
./run-local.sh | tee local-bench-output.txt
```

If PostgreSQL is on another host:

```bash
export PGHOST=127.0.0.1
```

## Docker database setup

This creates a `postgres:16` container, populates it using `setup-db.rb`, and leaves it running for the benchmark:

```bash
USERS=5000 CATEGORIES=32 TOPICS=50000 AVG_POSTS=6 ./setup-docker-db.sh
```

Then run the Docker Ruby matrix:

```bash
export PGDATABASE=discourse_sql_ft
export PGUSER=agent
export PGHOST=bench-pg
export BENCH_SECONDS=60
./run-docker.sh | tee docker-bench-output.txt
```

Cleanup:

```bash
docker rm -f bench-pg
docker network rm bench-net
```

## Requirements

- PostgreSQL
- Ruby 3.4.6 and/or Ruby 4.0.5
- YJIT-capable Ruby builds for `--yjit` runs
- Gems: `mini_sql`, `pg`, `activerecord`, `sequel`

The published pre-Sequel runs used:

- `mini_sql 1.6.0`
- `activerecord 8.1.3`
- `pg 1.6.3`
- 60 seconds per Ruby/layer/YJIT combination

Sequel support is present in the benchmark source; rerun the matrix after setup to generate results for your machine.

## Results

Published results are in:

- `results.csv`
- `results.json`

![Benchmark chart](chart.svg)

The checked-in chart/results currently reflect the MiniSql vs ActiveRecord matrix. Sequel has been added to the benchmark code and should be regenerated for a complete three-way comparison on your target machine.

## Caveats

- Not a full Rails request benchmark.
- The Docker run in the article was on a 1GB wasnotwas.com droplet; absolute throughput is not comparable to a proper benchmark host.
- The dataset is synthetic. Use your production-like data before drawing production conclusions.
- ActiveRecord buys model semantics. MiniSql and Sequel are more direct when the query is the point.
