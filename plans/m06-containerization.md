# M06 — Containerization + load balancing

## Goal

A `docker-compose.yml` with five services — nginx, pgbouncer, postgres (pre-baked), api-1, api-2 — that serves on port 9999, stays within 1 CPU + 350 MB total, and passes both `/ready` and `/fraud-score` through the load balancer. nginx communicates with each API instance via a Unix socket shared through a named Docker volume.

## Tasks

1. Write `Dockerfile.api` — `FROM ruby:4` base image, `bundle install`, start with `falcon serve --bind unix:///sockets/api.sock`.
2. Write `config/nginx.conf` — upstream block using Unix socket paths (`server unix:/sockets/api-1/api.sock` and `server unix:/sockets/api-2/api.sock`), `proxy_pass`, no business logic.
3. In `docker-compose.yml`, declare two named volumes — `sockets-api-1` and `sockets-api-2` — each mounted into both the corresponding API container and nginx so the socket file is visible to both sides.
4. Write `config/pgbouncer.ini` — point to postgres service, `pool_mode = transaction`, `max_client_conn = 100`, `default_pool_size = 10`.
5. Write `docker-compose.yml` with five services:
   - `postgres`: pre-baked `rinha-db` image, not exposed externally, `POSTGRES_PASSWORD` env.
   - `pgbouncer`: `edoburu/pgbouncer` image, mounts `pgbouncer.ini`, port 5432 internally only.
   - `api-1` / `api-2`: build from `Dockerfile.api`, `DATABASE_URL` points to `pgbouncer:5432`, mounts its own socket volume at `/sockets`.
   - `nginx`: depends on api-1 + api-2, mounts both socket volumes at `/sockets/api-1` and `/sockets/api-2`, exposes port 9999.
   - All five services declare `deploy.resources.limits`.
6. Confirm limits sum: CPU ≤ 1.0, memory ≤ 350 MB.
7. Create `submission` branch with only `docker-compose.yml`, `nginx.conf`, `pgbouncer.ini`, `info.json`.

## Acceptance criteria

Run with: `bundle exec ruby -Itest test/m06_containerization_test.rb` (requires `docker compose up --build -d` to be running).

```ruby
# test/m06_containerization_test.rb
require "minitest/autorun"
require "net/http"
require "json"
require "yaml"

class ContainerizationTest < Minitest::Test
  BASE_URI = URI("http://localhost:9999")

  STUB_PAYLOAD = {
    id: "tx-smoke",
    transaction: { amount: 100, installments: 1, requested_at: "2026-03-11T10:00:00Z" },
    customer: { avg_amount: 200, tx_count_24h: 1, known_merchants: [] },
    merchant: { id: "MERC-001", mcc: "5411", avg_amount: 80 },
    terminal: { is_online: false, card_present: true, km_from_home: 5 },
    last_transaction: nil
  }.freeze

  def test_ready_via_load_balancer
    res = Net::HTTP.get_response(URI("#{BASE_URI}/ready"))
    assert_equal "200", res.code, "/ready must return 200 through nginx"
  end

  def test_fraud_score_via_load_balancer
    body = post_fraud_score(STUB_PAYLOAD)
    assert body.key?("approved"), "response must include 'approved'"
    assert body.key?("fraud_score"), "response must include 'fraud_score'"
  end

  def test_total_cpu_within_budget
    assert_operator total_cpu, :<=, 1.0, "total declared CPU must not exceed 1.0"
  end

  def test_total_memory_within_budget
    assert_operator total_memory_mb, :<=, 350.0, "total declared memory must not exceed 350 MB"
  end

  private

  def post_fraud_score(payload)
    uri = URI("#{BASE_URI}/fraud-score")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = payload.to_json
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    JSON.parse(res.body)
  end

  def compose_config
    @compose_config ||= YAML.safe_load(`docker compose config`)
  end

  def total_cpu
    compose_config["services"].sum do |_, svc|
      svc.dig("deploy", "resources", "limits", "cpus").to_f
    end
  end

  def total_memory_mb
    compose_config["services"].sum do |_, svc|
      mem = svc.dig("deploy", "resources", "limits", "memory").to_s
      mem.end_with?("MB") ? mem.to_f : mem.to_f / 1024.0 / 1024.0
    end
  end
end
```
