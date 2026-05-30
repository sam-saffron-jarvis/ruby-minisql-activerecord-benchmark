# Ruby data-access benchmark: MiniSql, ActiveRecord, Sequel

A reproducible benchmark for Ruby PostgreSQL data access on a Discourse-ish workload.

Article: https://wasnotwas.com/writing/minisql-activerecord-and-ruby-4-a-small-benchmark-with-a-pulse/

## What it measures

This is **not** a full Rails request benchmark. It compares Ruby data-access layers for several forum-style PostgreSQL use cases:

1. Latest topic list
2. Topic header
3. Post stream
4. User card aggregate
5. Category dashboard aggregate
6. Temporary autosave/event write
7. Temporary readback count

Each use case is timed independently. Every query result is iterated and converted into tab-separated text. The benchmark records row counts and rendered byte counts so it measures data access plus lightweight serialization, not just `.length` on an already-materialized array.

The matrix supports:

- Ruby 3.4.6 and Ruby 4.0.5
- YJIT off and on (`RUBYOPT=--yjit`)
- MiniSql
- ActiveRecord
- Sequel

## Important: static database per benchmark run

The benchmark runners follow this lifecycle by default:

1. create a fresh benchmark database
2. populate it once with deterministic synthetic data and indexes
3. run the Ruby × YJIT × library × use-case matrix against that same database
4. drop/remove the database when finished

This avoids comparing runs that accidentally used different fixtures.

Use `KEEP_DB=1` if you want to inspect the generated database after the run. Use `USE_EXISTING_DB=1` only when you deliberately want to benchmark a pre-existing database.

## Local case benchmark

This creates a temporary local PostgreSQL database, populates it, runs each use case independently, then drops the DB:

```bash
mise install ruby@3.4.6 ruby@4.0.5
BENCH_SECONDS=10 BENCH_WARMUP_SECONDS=2 ./run-local-cases.sh
```

Results are written to `case-results.jsonl` by default. Use `RESULTS_JSONL=...` to choose another path.

Tune fixture size:

```bash
USERS=10000 CATEGORIES=48 TOPICS=100000 AVG_POSTS=8 \
  BENCH_SECONDS=10 BENCH_WARMUP_SECONDS=2 ./run-local-cases.sh
```

Keep the generated DB:

```bash
KEEP_DB=1 PGDATABASE=minisql_ar_bench BENCH_SECONDS=10 ./run-local-cases.sh
```

Use an existing DB intentionally:

```bash
USE_EXISTING_DB=1 PGDATABASE=my_existing_bench_db BENCH_SECONDS=10 ./run-local-cases.sh
```

## Legacy blended session benchmark

The old blended-session benchmark is still present:

```bash
BENCH_SECONDS=60 ./run-local.sh
```

That score is no longer the preferred headline metric. The category dashboard aggregate dominates the blended session, which hides the differences in row materialization and smaller hot-path reads. Use the case benchmark above for the article-style results.

## Docker run

Docker support remains available for reproducibility checks:

```bash
USERS=5000 CATEGORIES=32 TOPICS=50000 AVG_POSTS=6 \
  BENCH_SECONDS=60 ./run-docker.sh
```

The Docker runner currently uses the legacy blended benchmark. Treat constrained-host Docker results as directional unless you adapt it to the per-case runner.

## Manual database setup

`setup-db.rb` is the fixture generator used by the runners. It creates a synthetic Discourse-like dataset with the tables and indexes the benchmark expects.

Default dataset:

- 5,000 users
- 32 categories
- 50,000 topics
- roughly 350,000 posts with `AVG_POSTS=6`
- indexes for the benchmark queries

Manual use:

```bash
createdb minisql_ar_bench
mise x ruby@3.4.6 -- gem install pg --no-document
PGDATABASE=minisql_ar_bench PGUSER=$USER ruby setup-db.rb
```

## Index coverage

`setup-db.rb` creates the indexes used by the point-lookups and ordered hot-path queries:

| Workload step | Index/plan shape |
|---|---|
| latest page | `index_topics_on_category_public` for `(category_id, bumped_at desc)`, then primary-key lookups for joined users/categories |
| topic header | `topics_pkey`, then primary-key joins |
| post stream | `index_posts_on_topic_id_post_number` for `(topic_id, post_number)` |
| user card | `users_pkey` plus `index_posts_on_user_id_created_at` |
| temp readback | `index_bench_events_on_user_id` / temp-table user index once the write table has real cardinality |

Representative `EXPLAIN (ANALYZE, BUFFERS)` checks on the default fixture confirmed those plans. The one deliberate exception is `category_counts`: it aggregates topic counts across all categories, so PostgreSQL sensibly scans the visible/non-deleted topic slice and hashes/group-aggregates it. That is intended to represent a dashboard/reporting aggregate, not an accidental missing index.

## Requirements

- PostgreSQL client tools for local runs (`createdb`, `dropdb`)
- Docker for Docker runs
- Ruby 3.4.6 and/or Ruby 4.0.5
- YJIT-capable Ruby builds for `--yjit` runs
- Gems: `mini_sql`, `pg`, `activerecord`, `sequel`

The published case run used:

- `mini_sql 1.6.0`
- `activerecord 8.1.3`
- `sequel 5.104.0`
- `pg 1.6.3`
- 10 second measurement + 2 second warm-up per Ruby/layer/YJIT/use-case combination

## Results

Published case results are in:

- `case-results.csv`
- `case-results.json`

![Benchmark chart](case-chart.svg)

Legacy blended-session results are still in:

- `results.csv`
- `results.json`
- `chart.svg`

## Caveats

- Not a full Rails request benchmark.
- The dataset is synthetic. Use production-like data before drawing production conclusions.
- ActiveRecord buys model semantics. MiniSql and Sequel are more direct when the query is the point.
- The reporting aggregate is intentionally separated from the read/materialization hot paths because it is mostly PostgreSQL scan/aggregate work.
