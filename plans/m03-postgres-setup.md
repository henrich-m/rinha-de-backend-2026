# M03 — PostgreSQL + pgvector setup

## Goal

A running local postgres instance with the pgvector extension enabled, a `refs` table holding all 3,000,000 reference vectors, and a seed script that bulk-loads them in under 5 minutes. The `/ready` endpoint must proxy-check that postgres is reachable before returning 200.

## Tasks

1. Create `src/db.rb` — open an `Async::Postgres::Client` connection to `ENV["DATABASE_URL"]` (PgBouncer in production, direct postgres locally); expose `DB.query(sql, params)`. The async-postgres client is fiber-scheduler-aware, so Falcon fibers yield while waiting for query results instead of blocking the thread.
2. Create the schema:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   CREATE TABLE refs (
     id       SERIAL PRIMARY KEY,
     embedding vector(14) NOT NULL,
     is_fraud  BOOLEAN NOT NULL
   );
   ```
3. Create `scripts/seed.rb`:
   - Open `resources/references.json.gz` with `Zlib::GzipReader`.
   - Stream-parse with `oj` (SAX/callback mode) to avoid loading 284 MB of JSON at once.
   - Bulk-insert via postgres `COPY refs (embedding, is_fraud) FROM STDIN` using `conn.copy_data` — batch rows as `[0.01,0.08,...]\ttrue\n`.
4. Wire `/ready` to attempt `DB.query("SELECT 1")` and return 503 on failure.

## Acceptance criteria

Run with: `bundle exec ruby -Itest test/m03_postgres_test.rb` (requires `DATABASE_URL` env and a seeded database).

```ruby
# test/m03_postgres_test.rb
require "minitest/autorun"
require "pg"

class PostgresSetupTest < Minitest::Test
  def conn
    @conn ||= PG.connect(ENV.fetch("DATABASE_URL"))
  end

  def test_extension_is_enabled
    result = conn.exec("SELECT extname FROM pg_extension WHERE extname = 'vector'")
    refute_empty result.to_a, "pgvector extension must be installed"
  end

  def test_refs_table_exists
    result = conn.exec("SELECT to_regclass('public.refs')")
    refute_nil result[0]["to_regclass"], "refs table must exist"
  end

  def test_row_count
    result = conn.exec("SELECT COUNT(*) FROM refs")
    assert_equal "3000000", result[0]["count"], "refs must contain exactly 3M rows"
  end

  def test_vector_dimensionality
    result = conn.exec("SELECT array_length(embedding::float[], 1) AS dims FROM refs LIMIT 1")
    assert_equal "14", result[0]["dims"], "each embedding must have 14 dimensions"
  end

  def test_ready_endpoint_returns_200_when_db_is_up
    require "net/http"
    res = Net::HTTP.get_response(URI("http://localhost:9999/ready"))
    assert_equal "200", res.code, "/ready must return 200 when database is reachable"
  end
end
```
