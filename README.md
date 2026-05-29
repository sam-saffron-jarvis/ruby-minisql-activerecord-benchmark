# Ruby MiniSql vs ActiveRecord benchmark

A small reproducible benchmark comparing MiniSql and ActiveRecord on Ruby 3.4.6 and Ruby 4.0.5.

Article: https://wasnotwas.com/writing/minisql-activerecord-and-ruby-4-a-small-benchmark-with-a-pulse/

## What it measures

This is **not** a full Rails request benchmark. It compares the query/data access layer for a Discourse-ish workload.

Each benchmark session performs:

1. Latest topic list
2. Topic header
3. Post stream
4. User card aggregate
5. Category dashboard aggregate
6. Temporary autosave/event write
7. Temporary readback count

## Requirements

- PostgreSQL database containing Discourse-like `users`, `topics`, `posts`, and `categories` tables
- Ruby 3.4.6 and/or Ruby 4.0.5
- Gems: `mini_sql`, `pg`, `activerecord`

The published runs used:

- `mini_sql 1.6.0`
- `activerecord 8.1.3`
- `pg 1.6.3`
- 60 seconds per Ruby/layer combination

## Local run with mise

```bash
mise install ruby@3.4.6 ruby@4.0.5
export PGDATABASE=discourse_sql_ft
export PGUSER=agent
export BENCH_SECONDS=60
./run-local.sh
```

If PostgreSQL is on another host:

```bash
export PGHOST=127.0.0.1
```

## Docker Ruby run

Start or provide a PostgreSQL container on Docker network `bench-net`, reachable as `bench-pg`:

```bash
docker network create bench-net || true
docker run -d --name bench-pg --network bench-net \
  -e POSTGRES_DB=discourse_sql_ft \
  -e POSTGRES_USER=agent \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:16
```

Restore a compatible database into `bench-pg`, then:

```bash
export PGDATABASE=discourse_sql_ft
export PGUSER=agent
export PGHOST=bench-pg
export BENCH_SECONDS=60
./run-docker.sh | tee docker-bench-output.txt
```

## Results

![Benchmark chart](chart.svg)

| Environment | Ruby | Layer | Sessions/sec | Ops/sec |
|---|---|---|---:|---:|
| Jarvis container | 3.4.6 | MiniSql | 656.67 | 4596.67 |
| Jarvis container | 3.4.6 | ActiveRecord | 396.57 | 2775.96 |
| Jarvis container | 4.0.5 | MiniSql | 666.52 | 4665.61 |
| Jarvis container | 4.0.5 | ActiveRecord | 404.27 | 2829.92 |
| wasnotwas Docker | 3.4.6 | MiniSql | 149.73 | 1048.12 |
| wasnotwas Docker | 3.4.6 | ActiveRecord | 65.44 | 458.06 |
| wasnotwas Docker | 4.0.5 | MiniSql | 155.47 | 1088.31 |
| wasnotwas Docker | 4.0.5 | ActiveRecord | 69.04 | 483.28 |

## Caveats

- Not a full Rails request benchmark.
- The Docker run was on a 1GB wasnotwas.com droplet, so absolute throughput is intentionally not comparable to a proper benchmark host.
- The database is small and synthetic; use your own data before drawing production conclusions.
- ActiveRecord buys model semantics. MiniSql wins here because the query is the point.
