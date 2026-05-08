# M05 — Pre-baked postgres image + HNSW index

## Goal

A `Dockerfile.db` that uses a multi-stage build to produce a postgres image with all 3M vectors already loaded and an HNSW index pre-built. The container starts with data in place — no seed step at runtime. Under k6 load, p99 drops to sub-50ms.

## Tasks

1. Write `Dockerfile.db` with three stages:
   - **`FROM ruby:4 AS ruby-src`** — provides a known Ruby binary (no compilation needed).
   - **`FROM pgvector/pgvector:pg16 AS builder`** — use `pgvector/pgvector:pg16` as the base so pgvector is already installed at a pinned version; no separate installation or version-pinning needed. Copy Ruby from the ruby-src stage: `COPY --from=ruby-src /usr/local /usr/local`.
   - **`FROM pgvector/pgvector:pg16`** — final stage; copies the pre-populated data directory.

2. In the builder stage, build the data with a single `RUN` step. PostgreSQL refuses to run as root; use `gosu` (pre-installed in the postgres image):
   ```dockerfile
   ENV PGDATA=/pgdata
   RUN gosu postgres initdb -D /pgdata && \
       gosu postgres pg_ctl -D /pgdata \
         -o "-c listen_addresses='' -c maintenance_work_mem=8GB" start && \
       gosu postgres createdb rinha && \
       gosu postgres psql -d rinha -c "CREATE EXTENSION IF NOT EXISTS vector;" && \
       gosu postgres psql -d rinha -c \
         "CREATE TABLE refs (id SERIAL PRIMARY KEY, embedding vector(14), is_fraud BOOLEAN);" && \
       ruby scripts/seed.rb && \
       gosu postgres psql -d rinha -c \
         "CREATE INDEX ON refs USING hnsw (embedding vector_l2_ops) WITH (m=16, ef_construction=64);" && \
       printf "shared_buffers=64MB\nwork_mem=4MB\nmaintenance_work_mem=32MB\nmax_connections=20\n" \
         >> /pgdata/postgresql.conf && \
       gosu postgres pg_ctl -D /pgdata stop
   ```
   `maintenance_work_mem=8GB` during build lets the HNSW graph fit in memory (pgvector docs recommendation) — build completes in minutes rather than 30–60+. The final `postgresql.conf` override sets it back to 32MB for runtime.

3. In the final stage:
   ```dockerfile
   COPY --chown=postgres:postgres --from=builder /pgdata /var/lib/postgresql/data
   ```
   `--chown` ensures correct ownership without a separate `RUN chown` step. Both stages share the same `postgres` UID (999) from `pgvector/pgvector:pg16`, so ownership is consistent.

4. Update `CLAUDE.md`: document how to rebuild the pre-baked image, the HNSW index parameters, and the postgres tuning rationale.

## Acceptance criteria

Run with: `bundle exec ruby -Itest test/m05_baked_image_test.rb` (requires `rinha-db:local` image built and a container named `rinha-db-test` running on port 5432).

```ruby
# test/m05_baked_image_test.rb
require "minitest/autorun"
require "pg"

class BakedImageTest < Minitest::Test
  # Before running:
  #   docker build -f Dockerfile.db -t rinha-db:local .
  #   docker run -d --name rinha-db-test -p 5432:5432 \
  #     -e POSTGRES_PASSWORD=postgres rinha-db:local

  def conn
    url = ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/rinha")
    @conn ||= PG.connect(url)
  end

  def test_row_count
    result = conn.exec("SELECT COUNT(*) FROM refs")
    assert_equal "3000000", result[0]["count"], "pre-baked image must contain 3M rows"
  end

  def test_hnsw_index_exists
    result = conn.exec(<<~SQL)
      SELECT indexname FROM pg_indexes
      WHERE tablename = 'refs' AND indexdef ILIKE '%hnsw%'
    SQL
    refute_empty result.to_a, "HNSW index must exist on refs.embedding"
  end

  def test_postgres_conf_max_connections
    result = conn.exec("SHOW max_connections")
    assert_operator result[0]["max_connections"].to_i, :<=, 20
  end
end
```
