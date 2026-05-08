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
   - Service `api`: builds from `Dockerfile.dev`, mounts repo root to `/app`, mounts a named volume for the bundle cache (`/usr/local/bundle`), runs `bundle exec falcon serve --bind http://0.0.0.0:9999`, exposes port `9999:9999`.
3. Create `Gemfile` with gems: `falcon`, `roda`, `oj`, `async-postgres`, `minitest`.
4. Create `src/server.rb` — Roda app with both routes, wrapped in `Async do ... end`.
5. Route `GET /ready` → `200 OK`.
6. Route `POST /fraud-score` → parse JSON body with `oj`, return stub JSON.
7. Update `CLAUDE.md`: add dev commands (`docker compose -f docker-compose.dev.yml ...`), document `Dockerfile.dev` vs `Dockerfile.api` distinction, and the two API endpoints.

## Dev workflow

```bash
# First time — install gems into the named volume
docker compose -f docker-compose.dev.yml run --rm api bundle install

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
