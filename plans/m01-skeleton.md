# M01 — Project skeleton

## Goal

A Ruby HTTP server listening on port 9999 that responds to both required endpoints.
`GET /ready` returns 200. `POST /fraud-score` accepts a JSON body and returns a hardcoded stub response (`{ "approved": true, "fraud_score": 0.0 }`). No detection logic yet.

All development is done inside Docker — no local Ruby toolchain required.

## Tasks

1. Create `Dockerfile.dev`:
   - `FROM ruby:4`
   - `WORKDIR /app`
   - `COPY Gemfile Gemfile.lock* ./` then `RUN bundle install`
   - Source code is **not** copied — it is volume-mounted at runtime so edits take effect without rebuilding.
2. Create `docker-compose.dev.yml`:
   - Service `api`: builds from `Dockerfile.dev`, mounts repo root to `/app`, mounts a named volume for the bundle cache at `/usr/local/bundle` (default `BUNDLE_PATH` in official Ruby images — no explicit env needed), runs `bundle exec falcon serve --bind http://0.0.0.0:9999`, exposes port `9999:9999`.
3. Create `Gemfile` with gems: `falcon`, `roda`, `oj`, `async-postgres`, `minitest`, `rack-test` (test group).
4. Create `config.ru` at repo root — Falcon's `serve` command loads `config.ru` by default:
   ```ruby
   require_relative "src/server"
   run App
   ```
5. Create `src/server.rb` — defines `App`, a Roda subclass (valid Rack app via `.call`). No `Async::HTTP::Server.run` needed; Falcon's fiber scheduler wraps it automatically.
6. Route `GET /ready` → `200 OK`.
7. Route `POST /fraud-score` → parse body with `Oj.load(request.body.read, symbol_keys: false)`, return stub JSON `{ "approved": true, "fraud_score": 0.0 }`.
8. Generate and commit `Gemfile.lock` (see Dev workflow below).
9. Create `test/server_unit_test.rb` — unit-tests `src/server.rb` via `rack-test` (no live server needed):
   - Include `Rack::Test::Methods`, set `app = App`.
   - `GET /ready` → 200.
   - `POST /fraud-score` → 200, JSON body contains `approved` and `fraud_score`, `Content-Type` is `application/json`.
   - Run with: `bundle exec ruby -Itest test/server_unit_test.rb` (no Docker required beyond the bundle).
10. Update `CLAUDE.md`: add dev commands, document `Dockerfile.dev` vs `Dockerfile.api` distinction, `config.ru` entry point, and the two API endpoints.

## Dev workflow

```bash
# First time — install gems and capture the lockfile
docker compose -f docker-compose.dev.yml run --rm api bundle install
# Copy Gemfile.lock out and commit it for reproducible builds
docker compose -f docker-compose.dev.yml run --rm api cat Gemfile.lock > Gemfile.lock
git add Gemfile.lock && git commit -m "Add Gemfile.lock"

# Start the server (detached)
docker compose -f docker-compose.dev.yml up -d

# Run tests (inside the running container — localhost:9999 is Falcon)
docker compose -f docker-compose.dev.yml exec api bundle exec ruby -Itest test/m01_skeleton_test.rb

# Tail logs
docker compose -f docker-compose.dev.yml logs -f api

# Stop
docker compose -f docker-compose.dev.yml down
```

## Acceptance criteria

Run with: `docker compose -f docker-compose.dev.yml exec api bundle exec ruby -Itest test/m01_skeleton_test.rb`

```ruby
# test/m01_skeleton_test.rb
require "minitest/autorun"
require "net/http"
require "json"

class SkeletonTest < Minitest::Test
  BASE_URI = URI("http://localhost:9999")

  STUB_PAYLOAD = {
    id: "tx-1",
    transaction: { amount: 100, installments: 1, requested_at: "2026-03-11T18:45:53Z" },
    customer: { avg_amount: 200, tx_count_24h: 1, known_merchants: [] },
    merchant: { id: "MERC-001", mcc: "5411", avg_amount: 80 },
    terminal: { is_online: false, card_present: true, km_from_home: 5 },
    last_transaction: nil
  }.freeze

  def test_ready_returns_200
    res = Net::HTTP.get_response(URI("#{BASE_URI}/ready"))
    assert_equal "200", res.code
  end

  def test_fraud_score_returns_200
    res = post_fraud_score(STUB_PAYLOAD)
    assert_equal "200", res.code
  end

  def test_fraud_score_returns_approved_key
    body = JSON.parse(post_fraud_score(STUB_PAYLOAD).body)
    assert body.key?("approved"), "response must include 'approved'"
  end

  def test_fraud_score_returns_fraud_score_key
    body = JSON.parse(post_fraud_score(STUB_PAYLOAD).body)
    assert body.key?("fraud_score"), "response must include 'fraud_score'"
  end

  private

  def post_fraud_score(payload)
    uri = URI("#{BASE_URI}/fraud-score")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = payload.to_json
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end
end
```
