# M06 — Containerization + load balancing

## Goal

A `docker-compose.yml` with five services — nginx, pgbouncer, postgres (pre-baked), api-1, api-2 — that serves on port 9999, stays within 1 CPU + 350 MB total, and passes both `/ready` and `/fraud-score` through the load balancer. nginx communicates with each API instance via a Unix socket shared through a named Docker volume.

## Tasks

1. Write `Dockerfile.api`:
   ```dockerfile
   FROM ruby:4
   WORKDIR /app
   COPY Gemfile Gemfile.lock ./
   RUN bundle install
   COPY src/ ./src/
   COPY config/ ./config/
   COPY resources/normalization.json resources/mcc_risk.json ./resources/
   CMD ["bundle", "exec", "falcon", "serve", "--bind", "unix:///sockets/api.sock", "--count", "1"]
   ```
   Do **not** copy `resources/references.json.gz` — it is only needed by the DB image build.

2. Write `config/nginx.conf` — upstream uses Unix socket paths; nginx mounts both socket volumes:
   ```nginx
   upstream api {
     server unix:/sockets/api-1/api.sock;
     server unix:/sockets/api-2/api.sock;
     keepalive 32;
   }
   # proxy_next_upstream so a starting instance doesn't return 502 to clients
   proxy_next_upstream error timeout http_502 http_503;
   ```

3. Write `config/pgbouncer.ini`:
   ```ini
   [databases]
   rinha = host=postgres port=5432 dbname=rinha

   [pgbouncer]
   pool_mode = transaction
   max_client_conn = 100
   default_pool_size = 10
   listen_addr = 0.0.0.0
   listen_port = 5432
   auth_file = /etc/pgbouncer/userlist.txt
   ```
   Also create `config/userlist.txt`: `"postgres" "postgres"` (plaintext password; use md5 hash in production).
   Mount both files into the `edoburu/pgbouncer` container at `/etc/pgbouncer/`.

4. Write `docker-compose.yml` with five services:
   - `postgres`: `image: ghcr.io/henrichm/rinha-db:latest` (pre-baked; see Q38 — push before triggering a test). Not exposed externally.
   - `pgbouncer`: `edoburu/pgbouncer`, mounts `pgbouncer.ini` and `userlist.txt` at `/etc/pgbouncer/`.
   - `api-1` / `api-2`: build from `Dockerfile.api`, `DATABASE_URL=postgres://postgres:postgres@pgbouncer:5432/rinha`, each mounts its own socket volume (`sockets-api-1` / `sockets-api-2`) at `/sockets`. Add Docker healthcheck:
     ```yaml
     healthcheck:
       test: ["CMD", "curl", "-sf", "http://localhost:9999/ready"]
       interval: 5s
       timeout: 3s
       retries: 5
       start_period: 10s
     ```
   - `nginx`: depends on api-1 + api-2 (`condition: service_healthy`), mounts `sockets-api-1` at `/sockets/api-1` and `sockets-api-2` at `/sockets/api-2`, exposes port 9999. Both API instances write to `/sockets/api.sock` inside their own container — volume isolation keeps the files separate; nginx sees them at distinct paths.
   - All five services declare `deploy.resources.limits`.

5. Confirm limits sum: CPU ≤ 1.0, memory ≤ 350 MB.
6. Create `submission` branch as an orphan (`git checkout --orphan submission && git rm -rf .`). Add only `docker-compose.yml`, `nginx.conf`, `pgbouncer.ini`, `info.json` explicitly by name — never `git add .`. Build and push the pre-baked DB image to `ghcr.io/henrichm/rinha-db:latest` before triggering a preview test.
7. Update `CLAUDE.md`: document the five-service architecture, Unix socket volume setup, how to run the full stack locally, resource budget breakdown, and how to push the pre-baked image.

## Acceptance criteria

Run with: `bundle exec ruby -Itest test/m06_containerization_test.rb` (requires `docker compose up --build -d` running).

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
