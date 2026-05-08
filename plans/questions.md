# Open Questions

Questions raised during plan review. Answer inline, then move resolved items to the relevant milestone file or CLAUDE.md.

---

## M01 — Project Skeleton

**1. Falcon entry point** — `falcon serve` vs `falcon host`? Does it need a `falcon.rb` or `config.ru` at the repo root?

**Answer:** Use `falcon serve`. It loads `config.ru` from the current directory by default (no `falcon.rb` needed). Place `config.ru` at the repo root (or `/app` inside the container) with `run RodaApp` where `RodaApp` is the Rack-compatible Roda application class defined in `src/server.rb`. The m01 plan confirms this: the compose command is `bundle exec falcon serve --bind http://0.0.0.0:9999`.

**2. Roda + Falcon integration** — Does `server.rb` export a Rack constant picked up by `config.ru`, or does it call `Async::HTTP::Server.run` directly?

**Answer:** `server.rb` defines a Roda subclass that is a valid Rack app (Roda implements `.call`). `config.ru` requires `src/server.rb` and passes the class to `run`. Falcon's `serve` command discovers `config.ru` and runs the Rack app with its fiber scheduler — no `Async::HTTP::Server.run` call needed or appropriate here.

**3. `Gemfile.lock` inside Docker** — Will you commit a lockfile generated inside the container, or ship without one and accept non-reproducible builds?

**Answer:** Run `docker compose -f docker-compose.dev.yml run --rm api bundle install` once, then copy the generated `Gemfile.lock` out of the container (or commit it from the volume) so it is tracked in git. This gives reproducible builds. The `Dockerfile.dev` pattern `COPY Gemfile Gemfile.lock* ./` already handles both the present and absent lockfile case during bootstrap.

**4. `async-postgres` gem name** — Is `async-postgres` the exact gem name on RubyGems, and is it compatible with Ruby 4?

**Answer:** The exact gem name on RubyGems is `async-postgres` (by Samuel Williams). It is part of the async ecosystem that Falcon is built on and is compatible with Ruby 3.2+. Since Ruby 4.0 had not been released as of August 2025, treat the target as Ruby 3.4; `async-postgres` works on Ruby 3.4.

**5. Ruby 4 Docker image tag** — `ruby:4` likely doesn't exist on Docker Hub yet. What is the actual base image to use — `ruby:3.4`, a preview tag, or something else?

**Answer:** Use `ruby:3.4` (or `ruby:3.4-slim` for a smaller image). Ruby 4.0 had not been released as of August 2025, so `ruby:4` does not exist on Docker Hub. Replace every `FROM ruby:4` reference in `Dockerfile.dev` and `Dockerfile.api` with `FROM ruby:3.4`.

**6. Bundle cache volume path** — Does the `ruby:X` image use `/usr/local/bundle` as `BUNDLE_PATH`, or do you need to set it explicitly?

**Answer:** The official `ruby:X` Docker images set `BUNDLE_PATH=/usr/local/bundle` and `GEM_HOME=/usr/local/bundle` by default, so no explicit `ENV BUNDLE_PATH` is needed. Mounting a named volume at `/usr/local/bundle` in the dev compose file will correctly persist gems across container restarts.

**7. Falcon worker count in dev** — Is a single-process/single-worker Falcon sufficient for running tests, or do you need `--count N`?

**Answer:** A single process (the default, equivalent to `--count 1`) is sufficient for dev and test. Falcon uses the async fiber scheduler so a single process handles concurrent requests cooperatively. `--count N` spawns N worker processes (for multi-core), which is unnecessary and complicates test isolation in dev.

**8. Request body parsing in Roda** — Will you use `request.body.read` + `Oj.load`, a Roda plugin, or another mechanism for `/fraud-score`?

**Answer:** Use `Oj.load(request.body.read)` directly in the route block. The `roda` `:json` plugin is an alternative but adds overhead. Reading the raw body and calling `Oj.load` is idiomatic for this stack. Example: `payload = Oj.load(request.body.read, symbol_keys: false)`.

---

## M02 — Vectorization

**9. Resource file paths** — Does `Vectorizer.new("resources/...")` resolve correctly from `/app` inside the container, or do you need `__dir__`-relative paths?

**Answer:** Since the dev container sets `WORKDIR /app` and source is volume-mounted at `/app`, `"resources/normalization.json"` resolves correctly when Falcon is launched from `/app`. However, to be safe and portable (e.g. when running tests from arbitrary directories), use `File.expand_path("../../resources/normalization.json", __dir__)` inside `vectorizer.rb`. The test calls `Vectorizer.new("resources/normalization.json", "resources/mcc_risk.json")` from the test root, so the path is relative to `/app` — both approaches work as long as the process cwd is `/app`.

**10. Weekday encoding** — Ruby's `Date#wday` gives sun=0. The spec wants mon=0, sun=6. Confirmed formula: `(wday + 6) % 7`?

**Answer:** Yes, confirmed. `Date#wday` returns 0=Sunday, 1=Monday, …, 6=Saturday. Applying `(wday + 6) % 7` maps to 0=Monday, 1=Tuesday, …, 6=Sunday. The expected test value for `2026-03-11` (a Wednesday) is `day_of_week = 2/6 ≈ 0.3333`, consistent with Wednesday=2 under this formula.

**11. `requested_at` parsing** — `Time.iso8601` vs `DateTime.parse`? Which correctly handles the UTC offset?

**Answer:** Use `Time.iso8601(requested_at).utc`. `Time.iso8601` (from `require "time"`) correctly parses ISO 8601 strings including UTC offsets (`Z` and `+HH:MM`) and returns a `Time` object. Calling `.utc` normalizes it to UTC before extracting `.hour` and `.wday`. `DateTime.parse` also works but is slower and deprecated in newer Ruby. Avoid `Time.parse` as it is locale-sensitive.

**12. Float precision** — Should `vectorize` return raw Ruby `Float` (64-bit), or rounded to 4 decimal places? (Rounding affects how `oj` serializes the JSON.)

**Answer:** Return raw Ruby `Float` (64-bit). The test uses `assert_in_delta` with a tolerance of 0.001, so rounding is not required. The expected values in the test (e.g. `0.0041`, `0.1667`) are display-rounded reference values. `Oj` serializes Ruby `Float` with enough precision by default; do not round unless a downstream schema enforces it.

---

## M03 — PostgreSQL + pgvector Setup

**13. Dev postgres image** — Which exact image for the local `db` service: `pgvector/pgvector:pg16`, `ankane/pgvector`, or `postgres:16` with manual extension?

**Answer:** Use `pgvector/pgvector:pg18`. This is the official pgvector image maintained by the pgvector project, ships with the `vector` extension pre-installed, and requires only `CREATE EXTENSION IF NOT EXISTS vector;` — no manual compilation needed. `ankane/pgvector` is an older, less-maintained alternative. `postgres:16` requires installing pgvector from source during image build.

**14. `docker-compose.dev.yml` evolution** — Does M03 add a `db` service to the existing file in-place, or introduce a compose override? Does `api` get `depends_on: db`?

**Answer:** Add the `db` service in-place to `docker-compose.dev.yml`. Add `depends_on: [db]` to the `api` service so Falcon does not start before postgres is up (combine with a healthcheck on `db` using `pg_isready` for proper readiness gating). No separate override file is needed for dev.

**15. `async-postgres` connection API** — Is it `Async::Postgres::Client.new(...)` or `.connect(url)`? Does it accept a `DATABASE_URL` string directly?

**Answer:** The `async-postgres` gem wraps `pg` and exposes `Async::Postgres::Client`. Instantiate it with keyword arguments mirroring `PG.connect`: `Async::Postgres::Client.new(conninfo: ENV["DATABASE_URL"])`. It accepts a connection-string (`conninfo`) or individual keyword args (`host:`, `dbname:`, `user:`, `password:`). A `postgresql://` URL string passed as the `conninfo` keyword works because the underlying `pg` gem's `PG.connect` accepts it.

**16. Seed script DB client** — The seed runs standalone outside Falcon. Should it use a plain `PG::Connection` (not the async wrapper) directly via the `pg` gem?

**Answer:** Yes. The seed script runs as a plain Ruby process outside Falcon's fiber scheduler, so using `PG.connect(ENV["DATABASE_URL"])` (the synchronous `pg` gem) is correct and simpler. The async wrapper requires an active `Async` reactor; using it outside one raises an error. Use `conn.copy_data("COPY refs (embedding, is_fraud) FROM STDIN") { ... }` with the plain `pg` gem.

**17. COPY format for pgvector** — Does `[f1,f2,...]\ttrue\n` work for a `vector(14)` column in pgvector text COPY, or does it need a different format (e.g. `{f1,f2,...}`)?

**Answer:** pgvector accepts the text literal `[f1,f2,...]` (square brackets, comma-separated floats) in COPY FROM STDIN text format for a `vector` column. So the row format `"[0.01,0.08,...]\ttrue\n"` is correct. The `{...}` syntax is for PostgreSQL arrays, not pgvector vectors.

**18. `oj` SAX mode for 3M records** — Confirmed that `Oj`'s SAX interface handles a top-level JSON array of 3M objects without loading it all into memory? Is `yajl-ruby` a simpler alternative?

**Answer:** Yes, `Oj`'s SAX interface (`Oj::ScHandler` / `Oj.sc_parse`) handles streaming JSON without loading everything into memory. For a top-level array of objects, implement `hash_start`/`hash_end`/`add_value` callbacks to accumulate one record at a time. `yajl-ruby` is a simpler alternative with a streaming callback API (`Yajl::Parser.new` with a block), but it adds another gem dependency. Stick with `Oj` SAX since `oj` is already in the Gemfile.

**19. Seed script invocation** — `docker compose exec api bundle exec ruby scripts/seed.rb`, a `run --rm` container, or a dedicated `seed` compose service?

**Answer:** Use `docker compose -f docker-compose.dev.yml exec api bundle exec ruby scripts/seed.rb` (exec into the running api container). This avoids spawning an extra container and reuses the already-installed gem bundle. Alternatively, `run --rm` works if the api service is not running. A dedicated `seed` compose service is unnecessary overhead for a one-shot script.

**20. DB connection initialization timing** — Is `Async::Postgres::Client` initialized eagerly at server load (so `/ready` reliably fails fast) or lazily on first request?

**Answer:** Initialize eagerly at server load time, outside the route definitions. Assign the client to a constant (e.g. `DB = Async::Postgres::Client.new(conninfo: ENV["DATABASE_URL"])`) when `src/db.rb` is required. Then in `/ready`, call `DB.query("SELECT 1")` — if the connection is down, it raises and you rescue to return 503. Lazy initialization would cause the first real request to bear connection latency and make `/ready` unreliable as a health check.

---

## M04 — KNN Scoring

**21. `async-postgres` result type** — What does `DB.query` return? What is the Ruby expression to count rows where `is_fraud = true` from that result?

**Answer:** `async-postgres` wraps the `pg` gem's `PG::Result` object. `DB.query(sql, params)` returns a `PG::Result`. To count fraud rows: `result.count { |row| row["is_fraud"] == "t" }`. PostgreSQL returns booleans as the string `"t"` or `"f"` in text format via `pg`. Alternatively cast in SQL: `SELECT is_fraud::int FROM refs ...` and sum them.

**22. `-1` sentinel with `<->` operator** — Has the canonical test (`fraud_score=1.0` / `fraud_score=0.0`) been validated against a reference dataset that mixes null and non-null `last_transaction` rows?

**Answer:** The canonical test payloads both have `last_transaction: nil`, producing `-1` at indices 5 and 6. The reference dataset (`references.json.gz`) was generated to include vectors with `-1` sentinels at those positions for null-last-transaction cases, so neighbors of a `-1` vector will similarly have `-1` at those dimensions — the L2 distance still works correctly. The test assertions (`fraud_score=1.0` and `fraud_score=0.0`) are validated against the actual reference dataset, not a synthetic one.

**23. `$1::vector` parameterized cast** — Does pgvector accept `'[f1,...,f14]'::vector` when the value comes from a `$1` bind parameter, or does the OID need to be set explicitly?

**Answer:** Yes, `$1::vector` works correctly. When the query is `SELECT is_fraud FROM refs ORDER BY embedding <-> $1::vector LIMIT $2` and `$1` is the string `"[f1,...,f14]"`, PostgreSQL casts the text parameter to `vector` via the explicit `::vector` cast in the SQL string. No OID override is needed when using `pg`'s text protocol with an explicit cast expression.

**24. Client concurrency model under Falcon** — One `Async::Postgres::Client` shared across fibers, one per fiber, or a pool? Can a single client safely multiplex multiple in-flight queries?

**Answer:** `async-postgres` does not multiplex multiple in-flight queries on a single physical connection — PostgreSQL's wire protocol is request-response and does not support query pipelining in standard mode. A single `Async::Postgres::Client` will serialize concurrent queries (fibers queue up waiting for the connection). For production concurrency, use a pool: create a small `Async::Pool` or use multiple clients (e.g. 2–4 per API process, matching PgBouncer's `default_pool_size`). In dev with low concurrency, a single client is fine.

---

## M05 — Pre-Baked Postgres Image

**25. Ruby in the builder stage** — `postgres:16` is Debian-based. How is Ruby installed — `apt-get` (gives Ruby 3.x), Brightbox PPA, compiled from source, or copied from a `ruby:X` multi-stage layer?

**Answer:** Copy Ruby from a `ruby:3.4` multi-stage layer. Add a `FROM ruby:3.4 AS ruby-builder` stage before the postgres builder stage, then in the postgres builder stage use `COPY --from=ruby-builder /usr/local /usr/local`. This gives a known Ruby version without PPA setup or source compilation. Alternatively use `apt-get install -y ruby` (gives Ruby 3.x from Debian Bookworm) if the exact version does not matter — simpler but pins to whatever Debian ships.

**26. `initdb` + `pg_ctl` inside a `RUN` step** — Exact commands? Does this require running as the `postgres` OS user (`gosu postgres initdb`) or can it run as root?

**Answer:** PostgreSQL refuses to run as root, so use `gosu`. The `postgres:16` image ships `gosu`. Exact commands in the `RUN` step:
```
RUN gosu postgres initdb -D /pgdata && \
    gosu postgres pg_ctl -D /pgdata -o "-c listen_addresses=''" start && \
    gosu postgres psql -c "CREATE EXTENSION IF NOT EXISTS vector;" && \
    gosu postgres psql -c "CREATE TABLE ..." && \
    ruby scripts/seed.rb && \
    gosu postgres psql -c "CREATE INDEX ON refs USING hnsw ..." && \
    gosu postgres pg_ctl -D /pgdata stop
```
Set `PGDATA=/pgdata` and `POSTGRES_HOST_AUTH_METHOD=trust` (or a password) before this step.

**27. File ownership of copied pgdata** — After `COPY --from=builder /pgdata /var/lib/postgresql/data`, will file ownership (UID/GID) be correct for the `postgres` user, or does the final stage need a `chown`?

**Answer:** The final stage needs a `RUN chown -R postgres:postgres /var/lib/postgresql/data`. `COPY --from=builder` preserves numeric UIDs/GIDs from the builder stage, but both the builder and final stage use the same `postgres:16` base image, so the `postgres` user UID (typically 999) should be the same. However, to be safe and explicit, add the `chown` step or use `COPY --chown=postgres:postgres --from=builder /pgdata /var/lib/postgresql/data`.

**28. HNSW index build time** — Acceptable for the `docker build` workflow? Is `maintenance_work_mem=32MB` enough, or should it be temporarily raised during the build step?

**Answer:** Temporarily raise `maintenance_work_mem` during the build step for faster index construction. The official pgvector documentation recommends setting it high enough for the HNSW graph to fit entirely in memory — the docs use `SET maintenance_work_mem = '8GB'` as the example. Add `-c maintenance_work_mem=8GB` to the `pg_ctl start` command during the builder stage (e.g. `pg_ctl -D /pgdata -o "-c maintenance_work_mem=8GB -c listen_addresses=''" start`). At 32MB, building an HNSW index over 3M × 14-dim vectors will be very slow (likely 30–60+ minutes); at 8GB the graph fits in memory and build completes in a few minutes. Also consider `SET max_parallel_maintenance_workers = 7` for faster parallel construction. The final `postgresql.conf` in the baked image can still specify 32MB for runtime use.

**29. pgvector version pinning** — How are you pinning the pgvector version identically across the builder and final stage to prevent shared-library mismatches?

**Answer:** Install pgvector from source at a pinned git tag (e.g. `v0.8.0`) in both stages. Use a shared `ARG PGVECTOR_VERSION=0.8.0` and in each stage:
```
RUN apt-get install -y postgresql-server-dev-16 build-essential git && \
    git clone --branch v${PGVECTOR_VERSION} https://github.com/pgvector/pgvector.git && \
    cd pgvector && make && make install
```
Alternatively, install the `postgresql-16-pgvector` Debian package at a pinned version if the apt repository offers it. The `pgvector/pgvector:pg16` image pins a specific version — use it as the base for both stages instead of `postgres:16` to avoid manual installation.

**30. `postgresql.conf` overrides** — Are settings baked into `postgresql.conf` during the build, or applied via `-c` flags at runtime? If baked, the final stage inherits them automatically via the copied pgdata.

**Answer:** Bake them into `postgresql.conf` during the build step. After `initdb` and before seeding, write the overrides:
```
RUN echo "shared_buffers = 64MB\nwork_mem = 4MB\nmaintenance_work_mem = 32MB\nmax_connections = 20" \
    >> /pgdata/postgresql.conf
```
Since `COPY --from=builder /pgdata /var/lib/postgresql/data` copies the entire data directory including `postgresql.conf`, the final stage inherits them automatically. No `-c` flags at runtime are needed (though they can be used to override at launch if desired).

**31. Database name** — The M05 test defaults to `dbname=rinha`. The official postgres image creates `postgres` by default. When/how is the `rinha` database created — `createdb rinha`, `POSTGRES_DB=rinha`, or against the `postgres` default?

**Answer:** Create it explicitly during the builder `RUN` step after starting postgres: `gosu postgres createdb rinha`. Then run all subsequent `psql` commands against `rinha` (e.g. `psql -d rinha -c "CREATE EXTENSION ..."`). The `POSTGRES_DB` environment variable is handled by the official image's entrypoint at runtime — it does not apply during a `RUN` build step. The final stage inherits the `rinha` database via the copied pgdata.

---

## M06 — Containerization

**32. Falcon Unix socket filename per instance** — Both api-1 and api-2 use `--bind unix:///sockets/api.sock`. With each having its own volume at `/sockets`, both write the same filename. nginx mounts them at `/sockets/api-1` and `/sockets/api-2`. Is the Falcon `--bind` path the same for both instances, relying solely on volume isolation to separate the files?

**Answer:** Yes. Both api-1 and api-2 run `--bind unix:///sockets/api.sock` — the socket filename is identical. Volume isolation keeps them separate: api-1's `sockets-api-1` volume and api-2's `sockets-api-2` volume are distinct Docker volumes, each mounted at `/sockets` inside the respective container. nginx mounts `sockets-api-1` at `/sockets/api-1` and `sockets-api-2` at `/sockets/api-2`, so its upstream config uses `server unix:/sockets/api-1/api.sock` and `server unix:/sockets/api-2/api.sock`.

**33. `Dockerfile.api` COPY commands** — What exactly is copied: `src/`, `Gemfile*`, `config/`? Is `resources/references.json.gz` (~16 MB) copied into the API image or only into the DB image?

**Answer:** Copy into the API image: `Gemfile`, `Gemfile.lock`, `src/`, and `config/`. Do NOT copy `resources/references.json.gz` into the API image — it is only needed by the seed script during the DB image build (`Dockerfile.db`). The API reads vectors from postgres, not from the file at runtime. Also copy `resources/normalization.json` and `resources/mcc_risk.json` (small files needed by `Vectorizer` at runtime). Example:
```dockerfile
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY src/ ./src/
COPY resources/normalization.json resources/mcc_risk.json ./resources/
```

**34. PgBouncer `pgbouncer.ini` mount path** — `edoburu/pgbouncer` expects the config at `/etc/pgbouncer/pgbouncer.ini` or `/pgbouncer.ini`? Does it also need a `userlist.txt` for the postgres password?

**Answer:** The `edoburu/pgbouncer` image reads its config from environment variables by default (generating `pgbouncer.ini` at startup from `DATABASE_URL`, `POOL_MODE`, etc.), but it also accepts a mounted config at `/etc/pgbouncer/pgbouncer.ini`. If mounting a config file, use `/etc/pgbouncer/pgbouncer.ini`. A `userlist.txt` is required for password authentication — it must be at `/etc/pgbouncer/userlist.txt` and contain `"postgres" "md5hash_or_plaintext_password"`. Alternatively use `AUTH_TYPE=trust` in dev to skip the userlist.

**35. `pgbouncer.ini` hostname and database** — `host=` should be the Docker service name for postgres. What `dbname` does the `[databases]` section reference — `rinha`, `postgres`, or a wildcard?

**Answer:** Use the `rinha` database name. The `[databases]` section should be:
```ini
[databases]
rinha = host=postgres port=5432 dbname=rinha
```
The `host=` value is `postgres` (the Docker Compose service name). Applications connect to PgBouncer specifying `dbname=rinha`, and PgBouncer forwards to `postgres:5432/rinha`. A wildcard (`* = host=postgres`) also works if you want all database names forwarded, but explicit is clearer.

**36. Falcon worker count in production** — `--count 1` (single process, fiber concurrency) or `--count N`? Given 80 MB RAM per API instance, how many workers are feasible?

**Answer:** Use `--count 1` (single process). With 80 MB RAM per API instance, running multiple worker processes would exhaust memory quickly (Ruby baseline is ~30–40 MB per process before gems load). Falcon's async fiber model handles high concurrency within a single process via cooperative scheduling — multiple worker processes are for CPU-bound workloads, not I/O-bound ones like this. The pgvector query is I/O-bound, so fiber concurrency in one process is the right model.

**37. nginx zero-downtime readiness** — Is `proxy_next_upstream error timeout` needed? Do API services need a Docker healthcheck so nginx only receives traffic after Falcon is ready?

**Answer:** Add both. Set `proxy_next_upstream error timeout http_502 http_503` in nginx so a failed upstream attempt retries on the other API instance rather than returning an error to the client. Add a Docker healthcheck to each API service:
```yaml
healthcheck:
  test: ["CMD", "curl", "-sf", "http://localhost:9999/ready"]
  interval: 5s
  timeout: 3s
  retries: 5
  start_period: 10s
```
Then set `nginx: depends_on: {api-1: {condition: service_healthy}, api-2: {condition: service_healthy}}` so nginx only starts routing after Falcon is ready.

**38. Pre-baked image registry** — Is the `rinha-db` image built locally via a `build:` key or pulled from a public registry? The submission branch's `docker-compose.yml` must reference a publicly accessible image — when and how is it pushed?

**Answer:** The `submission` branch `docker-compose.yml` must reference a public registry image (e.g. `image: ghcr.io/henrichm/rinha-db:latest` or `docker.io/henrichm/rinha-db:latest`). The workflow: build locally with `docker build -f Dockerfile.db -t ghcr.io/henrichm/rinha-db:latest .`, then `docker push ghcr.io/henrichm/rinha-db:latest` before triggering a preview test. The `main` branch `Dockerfile.db` uses `build:` for local dev. The submission branch's `docker-compose.yml` uses only the `image:` key (no `build:`) so the Rinha Engine can pull it without source code.

---

## M07 — Submission Readiness

**39. k6 test script source** — Is it provided by the Rinha Engine (already in this repo), or does the developer write it?

**Answer:** The k6 test script is provided by the Rinha Engine (the official Rinha 2026 organizers). Preview tests are triggered by opening a GitHub issue with `rinha/test` in the body — the Engine pulls the submission branch, runs its own k6 script against your stack, and posts results as a comment. You do not write the k6 script. For local validation, you can write a simple k6 smoke test, but the official score comes from the Engine's script.

**40. `results.json` output format** — `k6 --out json` produces NDJSON; `--summary-export` produces a single JSON object. Which mode produces the `"type":"summary"` lines the M07 test expects?

**Answer:** `k6 --out json=results.json` produces NDJSON, but each line has `"type":"Metric"` (metric declaration) or `"type":"Point"` (data sample) — there is NO `"type":"summary"` line in this format. The `--summary-export export.json` flag produces a single JSON object (not NDJSON) containing aggregated metrics under a `"metrics"` key with `"values"` sub-keys. The M07 test code that uses `.find { _1&.dig("type") == "summary" }` over NDJSON lines will not find anything with `--out json`. To produce a file the test can parse as a summary: either (a) use `--summary-export results.json` and update the parser to read the single JSON object directly (no NDJSON scanning needed), or (b) write a custom `handleSummary(data)` function in the k6 script that emits a line `{"type":"summary","metrics":{...}}` to stdout/file. The `--summary-export` format has `metrics.http_req_failed.values.rate` at the top level of the JSON object, so access it as `JSON.parse(File.read("results.json")).dig("metrics","http_req_failed","values","rate")`.

**41. `final_score` validation** — Is "score > 0" checked manually from the GitHub issue comment, or is there a local scoring script? What counts as "the preview test passes" locally?

**Answer:** Locally, "preview test passes" means: `results.json` exists, `failure_rate < 0.15` (from the k6 summary metrics `http_req_failed.values.rate`), and p99 < 2000ms. There is no local `final_score` calculation script — the formula `score_p99 + score_det` requires the detection accuracy data that only the Engine has. The official score comes from the GitHub issue comment posted by the Rinha Engine after a `rinha/test` trigger. Check manually that the comment shows `final_score > 0`.

**42. `info.json` field formats** — Is `participants` an array of strings? Is `social` a URL string or a map? Is `stack` a free-form string or an array?

**Answer:** Based on the official `SUBMISSION.md` example: `participants` is an array of strings (full names), `social` is an array of URL strings, `stack` is an array of strings (technology names), and `open_to_work` is a boolean. Example:
```json
{
  "participants": ["Henrich Moraes"],
  "social": ["https://github.com/henrichm"],
  "source-code-repo": "https://github.com/henrichm/rinha-2026",
  "stack": ["ruby", "falcon", "postgres", "pgvector", "nginx"],
  "open_to_work": false
}
```

**43. `submission` branch creation strategy** — Orphan branch (`git checkout --orphan submission`) or regular branch? What is the workflow to update only the 4 allowed files without accidentally committing source?

**Answer:** Use an orphan branch: `git checkout --orphan submission && git rm -rf .` to start with a clean working tree. Then copy only the 4 files (`docker-compose.yml`, `nginx.conf`, `pgbouncer.ini`, `info.json`) into the clean tree, `git add` them explicitly by name, and commit. To update: `git checkout submission`, edit the relevant files, `git add docker-compose.yml nginx.conf pgbouncer.ini info.json` (never `git add .`), then commit. Return to main with `git checkout main`. The orphan branch guarantees no source history leaks into `submission`.

**44. GitHub issue target repository** — The `rinha/test` trigger issue: is it opened on your own implementation repo, on the official Rinha 2026 org repo, or somewhere else?

**Answer:** Open the issue on the **official Rinha 2026 organization repository** (`zanfranceschi/rinha-de-backend-2026` on GitHub), not on your own repo. The SUBMISSION.md example links to `https://github.com/zanfranceschi/rinha-de-backend-2026/issues/49`. The Rinha Engine scans that repo for open issues containing `rinha/test [optional-submission-id]` in the body, runs the test against the `submission` branch of the repo registered in your participants file, and posts results as a comment on that issue.
