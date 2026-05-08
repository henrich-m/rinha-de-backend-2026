# M05 — Pre-baked postgres image + HNSW index

## Goal

A `Dockerfile.db` that uses a multi-stage build to produce a postgres image with all 3M vectors already loaded and an HNSW index pre-built. The container starts with data in place — no seed step at runtime. Under k6 load, p99 drops to sub-50ms.

## Tasks

1. Write `Dockerfile.db`:
   - **Builder stage** (`FROM postgres:16 AS builder`):
     - Install pgvector and Ruby 4 (verify `ruby:4` image tag is available on Docker Hub before building).
     - Copy `resources/references.json.gz` and `scripts/seed.rb`.
     - Run `initdb`, start postgres temporarily, create extension + schema, run seed script, create HNSW index, stop postgres.
   - **Final stage** (`FROM postgres:16`):
     - Install pgvector runtime.
     - `COPY --from=builder /pgdata /var/lib/postgresql/data`.
2. HNSW index DDL (added to seed script or a separate SQL step):
   ```sql
   CREATE INDEX ON refs USING hnsw (embedding vector_l2_ops)
   WITH (m = 16, ef_construction = 64);
   ```
3. Set `PGDATA=/pgdata` in the builder so it copies to a clean path.
4. Tune postgres for the memory budget — add `postgresql.conf` overrides:
   ```
   shared_buffers = 64MB
   work_mem = 4MB
   maintenance_work_mem = 32MB
   max_connections = 20
   ```

## Acceptance criteria

Run with: `bundle exec ruby -Itest test/m05_baked_image_test.rb` (requires `rinha-db:local` image to be built and a container named `rinha-db-test` running on port 5432).

```ruby
# test/m05_baked_image_test.rb
require "minitest/autorun"
require "pg"

class BakedImageTest < Minitest::Test
  # Before running: docker build -f Dockerfile.db -t rinha-db:local .
  #                 docker run -d --name rinha-db-test -p 5432:5432 \
  #                   -e POSTGRES_PASSWORD=postgres rinha-db:local

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
