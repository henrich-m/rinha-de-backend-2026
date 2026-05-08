# M03 — PostgreSQL + pgvector setup

## Goal

A running local postgres instance with the pgvector extension enabled, a `refs` table holding all 3,000,000 reference vectors, and a seed script that bulk-loads them in under 5 minutes. The `/ready` endpoint must proxy-check that postgres is reachable before returning 200.

## Tasks

1. Add a `db` service in-place to `docker-compose.dev.yml` using `pgvector/pgvector:pg16` (ships with the extension pre-installed). Add a healthcheck (`pg_isready`) and `depends_on: {db: {condition: service_healthy}}` to the `api` service so Falcon waits for postgres before starting.
2. Create the schema (run once via `exec db psql` or in the seed script):
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   CREATE TABLE refs (
     id       SERIAL PRIMARY KEY,
     embedding vector(14) NOT NULL,
     is_fraud  BOOLEAN NOT NULL
   );
   ```
3. Create `src/db.rb` — define a `Db` class that wraps `Async::Postgres::Client` and assign a global `DB` constant. Accept an optional `client:` keyword argument so unit tests can inject a stub without a real database:
   ```ruby
   require "async/postgres"

   class Db
     def initialize(client: Async::Postgres::Client.new(conninfo: ENV.fetch("DATABASE_URL")))
       @client = client
     end

     def query(sql, params = [])
       @client.query(sql, params)
     end
   end

   DB = Db.new
   ```
   In `/ready`, rescue any exception from `DB.query("SELECT 1")` and return 503.
4. Create `scripts/seed.rb` — runs as a plain Ruby process (outside Falcon), so use synchronous `PG.connect(ENV.fetch("DATABASE_URL"))`:
   - Open `resources/references.json.gz` with `Zlib::GzipReader`.
   - Stream-parse with `Oj` SAX (`Oj::ScHandler` / `Oj.sc_parse`) — processes one record at a time without loading 284 MB into memory.
   - Bulk-insert via `conn.copy_data("COPY refs (embedding, is_fraud) FROM STDIN")` using `conn.put_copy_data("[f1,f2,...]\ttrue\n")` — pgvector accepts `[f1,f2,...]` square-bracket notation in text-mode COPY.
5. Create `test/db_unit_test.rb` — unit-tests `src/db.rb` using a stub client (no real DB needed):
   - Verify `knn` sends the correct SQL and wraps the vector as `[f1,f2,…]` text.
   - Verify `ready?` returns `true` when `query` succeeds and `false` when it raises.
   - Use Minitest mocks (`Minitest::Mock`) or a simple `Struct`-based stub for the client.
   Example structure:
   ```ruby
   StubClient = Struct.new(:result) do
     def query(*, **) = result
   end

   def test_knn_returns_client_result
     rows = [{"is_fraud" => "t"}, {"is_fraud" => "f"}]
     db = Db.new(client: StubClient.new(rows))
     assert_equal rows, db.knn([0.1] * 14)
   end
   ```
6. Update `CLAUDE.md`: document `DATABASE_URL` env var, `refs` schema, seed invocation, and how to start the dev postgres service.

## Dev workflow additions (from M03)

```bash
# Add db service to docker-compose.dev.yml, then restart
docker compose -f docker-compose.dev.yml up -d

# Run the seed (exec into the running api container — reuses the installed bundle)
docker compose -f docker-compose.dev.yml exec api bundle exec ruby scripts/seed.rb
```

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
