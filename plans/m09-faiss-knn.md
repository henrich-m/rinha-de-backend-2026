# M09 — Replace pgvector with FAISS IVFFlat (in-memory KNN)

## Goal

Eliminate PostgreSQL + pgvector entirely. Replace with a dedicated in-memory search service backed by **FAISS IVFFlat**, communicating with the API instances over a **Unix socket**. The FAISS index is trained and baked into the Docker image at build time, so container startup is near-instant.

---

## Why IVFFlat

3M × 14 dims × 4 bytes (float32) = **168 MB** of raw vectors — too large for each API instance to own a copy (2 × ~200 MB exceeds the 350 MB budget). A dedicated `search` service holds the data once.

| Index | p99 | Memory (3M×14) | Fits budget |
|---|---|---|---|
| numo-narray brute force | ~20–80 ms | 168 MB | yes |
| numo-narray + BLAS trick | ~2–8 ms | 168 MB | yes |
| **IVFFlat** | **~0.5–2 ms** | **~185 MB** | **yes** |
| HNSWFlat | ~0.1–2 ms | ~520 MB | **no** — graph edges alone need ~380 MB |

IVFFlat clusters the dataset into `nlist` buckets; a query probes only the `nprobe` nearest clusters. No graph storage overhead — just cluster assignments alongside the raw vectors.

---

## Architecture

```
nginx:9999  →  api-1:9292, api-2:9292   (round-robin, unchanged)
                      │  HTTP over Unix socket (~0.05 ms RTT, no TCP)
              search  ←  FAISS IVFFlat index, baked into image
              (binds on /sockets/knn.sock — shared Docker volume)
```

A shared `sockets` Docker volume is mounted into `search`, `api-1`, and `api-2`. The search service creates the socket file at bind; the API instances open it directly. No port binding, no TCP stack.

---

## Memory Budget (≤ 350 MB total)

| Service | Limit  | What it holds |
|---------|--------|---------------|
| search  | 225 MB | FAISS index (~185 MB) + Ruby overhead |
| api-1   |  55 MB | Falcon + Roda + Vectorizer |
| api-2   |  55 MB | same |
| nginx   |  10 MB | stock alpine |
| **Total** | **345 MB** | |

---

## IVF Parameters

| Parameter | Value | Rationale |
|---|---|---|
| `nlist` | 2048 | ≈ 1.2 × √3M; powers-of-two are efficient for FAISS |
| `nprobe` | 64 | probes 3.1 % of dataset; >99 % recall in practice |
| `d` | 14 | fixed by spec |

`nprobe` is exposed as `KNN_NPROBE` env var — tunable at runtime without a rebuild.

| `nprobe` | Dataset searched | Recall | Latency |
|---|---|---|---|
| 16 | 0.8 % | ~95 % | ~0.3 ms |
| 32 | 1.6 % | ~98 % | ~0.5 ms |
| **64** | **3.1 %** | **>99 %** | **~1 ms** |
| 128 | 6.3 % | ~99.9 % | ~2 ms |

---

## Files to Delete

| File | Reason |
|------|--------|
| `src/db.rb` | postgres connection pool — replaced by Unix socket client |
| `Dockerfile.db` | baked postgres image — replaced by Dockerfile.search |
| `scripts/seed.rb` | postgres seeding — replaced by knn_trainer.rb |

---

## Files to Create

### `src/knn_trainer.rb`

Runs once inside `docker build` (Stage 1). Trains the IVF index via k-means, adds all 3M vectors, writes `index.faiss` and `labels.bin`.

```ruby
# frozen_string_literal: true
require "faiss"
require "numo/narray"
require "zlib"
require "oj"

REFS_PATH   = "resources/references.json.gz"
INDEX_PATH  = "index.faiss"
LABELS_PATH = "labels.bin"
NLIST       = 2048
DIM         = 14

vecs   = []
labels = []

Zlib::GzipReader.open(REFS_PATH) do |gz|
  Oj.load(gz, symbol_keys: false).each do |entry|
    vecs   << entry["vector"]
    labels << (entry["label"] == "fraud" ? 1 : 0)
  end
end

matrix    = Numo::SFloat[*vecs]
quantizer = Faiss::IndexFlatL2.new(DIM)
index     = Faiss::IndexIVFFlat.new(quantizer, DIM, NLIST, :l2)
index.train(matrix)
index.add(matrix)
index.save(INDEX_PATH)

File.binwrite(LABELS_PATH, Numo::Int8[*labels].to_binary)

puts "Trained #{NLIST}-cluster IVF index over #{vecs.size} vectors → #{INDEX_PATH}"
```

---

### `src/knn.rb`

Loads the baked index at container startup (~2–3 s). Queries use FAISS's C++ search path internally.

```ruby
# frozen_string_literal: true
require "faiss"
require "numo/narray"

class Knn
  DIM    = 14
  NPROBE = Integer(ENV.fetch("KNN_NPROBE", "64"))

  def initialize(index_path, labels_path)
    @ready        = false
    @index        = Faiss::Index.load(index_path)
    @index.nprobe = NPROBE
    @labels       = Numo::Int8.from_binary(File.binread(labels_path), [@index.ntotal])
    @ready        = true
  end

  def ready? = @ready

  # Returns Array of k integers: 1 = fraud, 0 = legit
  def search(vector, k: 5)
    q              = Numo::SFloat[*vector].reshape(1, DIM)
    _dists, indices = @index.search(q, k)
    indices[0].to_a.map { |i| @labels[i] }
  end
end
```

---

### `src/search_server.rb`

```ruby
# frozen_string_literal: true
require "roda"
require "oj"

class SearchApp < Roda
  route do |r|
    r.get "ready" do
      if KNN.ready?
        response.status = 200
        "Ready"
      else
        response.status = 503
        "Loading"
      end
    end

    r.post "knn" do
      response["Content-Type"] = "application/json"
      body    = Oj.load(r.body.read, symbol_keys: false)
      results = KNN.search(body["vector"], k: body.fetch("k", 5))
      Oj.dump({ "results" => results })
    end
  end
end
```

---

### `config.search.ru`

```ruby
# frozen_string_literal: true
require_relative "src/knn"
KNN = Knn.new(
  File.expand_path("index.faiss", __dir__),
  File.expand_path("labels.bin",  __dir__)
)

require_relative "src/search_server"
run SearchApp
```

---

### `Dockerfile.search`

Two-stage build. Stage 1 runs the trainer (5–15 min, pays once at build time). Stage 2 is the slim runtime image.

```dockerfile
# ── Stage 1: train ──────────────────────────────────────────────
FROM ruby:4 AS trainer

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake g++ libopenblas-dev && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY src/knn_trainer.rb ./src/
COPY resources/references.json.gz ./resources/

RUN bundle exec ruby src/knn_trainer.rb

# ── Stage 2: runtime ────────────────────────────────────────────
FROM ruby:4

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl libopenblas-dev libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
ENV RUBY_YJIT_ENABLE=1

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY config.search.ru ./
COPY src/knn.rb src/search_server.rb ./src/
COPY --from=trainer /app/index.faiss /app/labels.bin ./

CMD ["bundle", "exec", "falcon", "serve", "--bind", "unix:///sockets/knn.sock", "--count", "1"]
```

---

## Files to Modify

### `Gemfile`

Remove `pg`, `async-pool`. Add `faiss` and `numo-narray`.

```ruby
source "https://rubygems.org"

gem "falcon"
gem "io-endpoint"
gem "roda"
gem "oj"
gem "numo-narray"
gem "faiss"

group :test do
  gem "minitest"
  gem "rack-test"
  gem "rake"
end
```

---

### `config.ru`

Remove DB initialization. Add `SEARCH_SOCKET` constant.

```ruby
# frozen_string_literal: true
require_relative "src/vectorizer"
VECTORIZER = Vectorizer.new(
  File.expand_path("resources/normalization.json", __dir__),
  File.expand_path("resources/mcc_risk.json", __dir__)
)

SEARCH_SOCKET = ENV.fetch("SEARCH_SOCKET", "/sockets/knn.sock")

require_relative "src/server"
run App
```

---

### `src/server.rb`

Replace `DB.knn()` with an `Async::HTTP::Client` call over the Unix socket. `io-endpoint` is already in the Gemfile; `async-http` arrives as a Falcon transitive dependency — no new gems needed.

Labels are now integers (`1`/`0`), not postgres strings (`"t"`/`"f"`).

```ruby
# frozen_string_literal: true
require "roda"
require "oj"
require "async/http/client"
require "async/http/endpoint"
require "io/endpoint/unix_endpoint"

module Search
  def self.client
    # Lazy — safe because Falcon initializes inside an Async context.
    @client ||= Async::HTTP::Client.new(
      Async::HTTP::Endpoint.new(
        URI("http://localhost"),
        endpoint: IO::Endpoint.unix(SEARCH_SOCKET)
      )
    )
  end

  def self.ready?
    client.get("/ready")
  end

  def self.knn(vector)
    body = Oj.dump({ "vector" => vector, "k" => 5 })
    resp = client.post("/knn",
      [["content-type", "application/json"], ["content-length", body.bytesize.to_s]],
      [body]
    )
    Oj.load(resp.read, symbol_keys: false)
  end
end

class App < Roda
  route do |r|
    r.get "ready" do
      resp = Search.ready?
      response.status = resp.status
      resp.read
    rescue
      response.status = 503
      "Search not ready"
    end

    r.post "fraud-score" do
      response["Content-Type"] = "application/json"
      payload = Oj.load(r.body.read, symbol_keys: false)
      vector  = VECTORIZER.vectorize(payload)
      begin
        data        = Search.knn(vector)
        fraud_count = data["results"].count { |v| v == 1 }
        fraud_score = fraud_count.to_f / 5
        Oj.dump({ "approved" => fraud_score < 0.6, "fraud_score" => fraud_score })
      rescue
        Oj.dump({ "approved" => true, "fraud_score" => 0.0 })
      end
    end
  end
end
```

---

### `docker-compose.yml`

Replace `postgres` with `search`. Add shared `sockets` volume. Startup is fast (~2–3 s) so `start_period` is short.

```yaml
services:
  search:
    build:
      context: .
      dockerfile: Dockerfile.search
    image: ghcr.io/henrichm/rinha-search:latest
    environment:
      KNN_NPROBE: "64"
    volumes:
      - sockets:/sockets
    healthcheck:
      test: ["CMD-SHELL", "curl -sf --unix-socket /sockets/knn.sock http://localhost/ready"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 15s
    deploy:
      resources:
        limits:
          memory: 225MB

  api-1:
    build:
      context: .
      dockerfile: Dockerfile.api
    image: ghcr.io/henrichm/rinha-api:latest
    environment:
      SEARCH_SOCKET: /sockets/knn.sock
    volumes:
      - .:/app
      - bundle_cache:/usr/local/bundle
      - sockets:/sockets
    depends_on:
      search:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://127.0.0.1:9292/ready"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    deploy:
      resources:
        limits:
          memory: 55MB

  api-2:
    # identical to api-1

  nginx:
    image: nginx:alpine
    ports:
      - "9999:9999"
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      api-1:
        condition: service_healthy
      api-2:
        condition: service_healthy

volumes:
  bundle_cache:
  sockets:
```

---

### `test/server_unit_test.rb`

- Stub `Search.knn` / `Search.ready?` instead of `DB`
- Update fraud-count check: `v == 1` instead of `row["is_fraud"] == "t"`

---

## Verification

```bash
# First build (training runs inside — takes ~5-15 min)
docker compose build search
docker compose up -d

# Search service should be healthy within 15s
curl localhost:9999/ready
# → 200 OK

# Smoke test
curl -s -X POST localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d "$(ruby -e 'require "json"; puts JSON.parse(File.read("resources/example-payloads.json")).first.to_json')"
# → {"approved":true,"fraud_score":0.0}

# Unit tests
docker compose exec api-1 bundle exec ruby -Itest test/server_unit_test.rb

# Integration (KNN scoring)
docker compose exec api-1 bundle exec ruby -Itest test/m04_knn_scoring_test.rb

# Quick p99 estimate (100 requests)
for i in $(seq 1 100); do
  curl -s -o /dev/null -w "%{time_total}\n" -X POST localhost:9999/fraud-score \
    -H "Content-Type: application/json" \
    -d '{"id":"x","transaction":{"amount":150,"installments":1,"requested_at":"2024-01-15T14:30:00Z"},"customer":{"avg_amount":120,"tx_count_24h":3,"known_merchants":["m1"]},"merchant":{"id":"m2","mcc":"5812","avg_amount":200},"terminal":{"is_online":true,"card_present":true,"km_from_home":5},"last_transaction":null}'
done | sort -n | awk 'NR==95'
# Target: < 0.010 (10 ms)
```
