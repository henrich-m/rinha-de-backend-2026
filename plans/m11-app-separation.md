# M11 — Separate API and Search into independent apps

## Context

The single `Gemfile` at the repo root installs all gems for both services, including `faiss` and `numo-narray` in the API container even though the API never uses them. Splitting into `api/` and `search/` subdirectories — each with its own `Gemfile`, `Dockerfile`, and source tree — removes the dead weight from the API image and is the first concrete step toward hitting the 30MB memory target.

No source code is shared between the two services today, so the split is clean.

---

## Target directory layout

```
api/
├── Dockerfile
├── Gemfile             ← falcon, io-endpoint, roda, oj (no faiss/numo)
├── Gemfile.lock
├── config.ru
├── src/
│   ├── server.rb
│   └── vectorizer.rb
├── resources/
│   ├── mcc_risk.json
│   └── normalization.json
└── test/
    ├── server_unit_test.rb
    └── (other api tests)

search/
├── Dockerfile          ← 2-stage: trainer + runtime
├── Gemfile             ← falcon, io-endpoint, roda, oj, numo-narray, faiss
├── Gemfile.lock
├── config.ru           ← renamed from config.search.ru
├── src/
│   ├── knn.rb
│   ├── search_server.rb
│   └── knn_trainer.rb
└── resources/
    └── references.json.gz

config/nginx.conf       ← stays at repo root (shared)
docker-compose.yml      ← updated build contexts
```

---

## Step-by-step

### 1 — Create directory trees

```bash
mkdir -p api/src api/resources api/test
mkdir -p search/src search/resources
```

### 2 — Move API files

```bash
cp config.ru                        api/config.ru
cp src/server.rb                    api/src/server.rb
cp src/vectorizer.rb                api/src/vectorizer.rb
cp resources/mcc_risk.json          api/resources/mcc_risk.json
cp resources/normalization.json     api/resources/normalization.json
cp test/server_unit_test.rb         api/test/server_unit_test.rb
# copy any other api-only tests
```

### 3 — Move Search files

```bash
cp config.search.ru                 search/config.ru
cp src/knn.rb                       search/src/knn.rb
cp src/search_server.rb             search/src/search_server.rb
cp src/knn_trainer.rb               search/src/knn_trainer.rb
cp resources/references.json.gz     search/resources/references.json.gz
```

### 4 — Write api/Gemfile

```ruby
# frozen_string_literal: true
source "https://rubygems.org"

gem "falcon"
gem "io-endpoint"
gem "roda"
gem "oj"

group :test do
  gem "minitest"
  gem "rack-test"
  gem "rake"
end
```

### 5 — Write search/Gemfile

```ruby
# frozen_string_literal: true
source "https://rubygems.org"

gem "falcon"
gem "io-endpoint"
gem "roda"
gem "oj"
gem "numo-narray"
gem "faiss"

group :test do
  gem "minitest"
  gem "rake"
end
```

### 6 — Generate Gemfile.lock for each

Run inside Docker so the native gems compile for linux/amd64:

```bash
docker run --rm -v $(pwd)/api:/app -w /app ruby:4 bundle install
docker run --rm -v $(pwd)/search:/app -w /app \
  ruby:4 bash -c "apt-get update -qq && apt-get install -y cmake g++ libblas-dev liblapack-dev && bundle install"
```

### 7 — Write api/Dockerfile

Identical to the current `Dockerfile.api` but build context is now `api/` (paths are already relative):

```dockerfile
FROM ruby:4

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
ENV RUBY_YJIT_ENABLE=1

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

CMD ["bundle", "exec", "falcon", "serve", "--bind", "http://0.0.0.0:9292", "--count", "1"]
```

Note: `libblas-dev` and `liblapack-dev` are dropped — they're only needed for FAISS compilation.

### 8 — Update search/Dockerfile

Change paths to match the new layout (build context is now `search/`):

```dockerfile
# Stage 1: train the index
FROM ruby:4 AS trainer

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake g++ libblas-dev liblapack-dev && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY src/knn_trainer.rb src/
COPY resources/references.json.gz resources/

RUN bundle exec ruby src/knn_trainer.rb

# Stage 2: runtime
FROM ruby:4

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl libblas-dev liblapack-dev libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
ENV RUBY_YJIT_ENABLE=1

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY --from=trainer /app/index.faiss /app/labels.bin ./
COPY config.ru src/ ./src/

CMD ["bundle", "exec", "falcon", "serve", \
     "--bind", "http://0.0.0.0:9294", "--count", "1", \
     "--config", "config.ru"]
```

### 9 — Update docker-compose.yml build contexts

```yaml
services:
  search:
    build:
      context: ./search
      dockerfile: Dockerfile
    image: ghcr.io/henrichm/rinha-search:latest
    # ...

  api-1:
    build:
      context: ./api
      dockerfile: Dockerfile
    image: ghcr.io/henrichm/rinha-api:latest
    environment:
      SEARCH_URL: http://search:9294
    # remove volume mount or update to ./api:/app
    # ...

  api-2:
    build:
      context: ./api
      dockerfile: Dockerfile
    # ...
```

### 10 — Delete old files at repo root (after validating the build)

```bash
rm Dockerfile.api Dockerfile.search
rm config.ru config.search.ru
rm -r src/
rm Gemfile Gemfile.lock
# keep resources/ at root only if needed by tests; otherwise remove
```

---

## Files changed

| File | Action |
|------|--------|
| `Dockerfile.api` | → `api/Dockerfile` (drop libblas/liblapack) |
| `Dockerfile.search` | → `search/Dockerfile` (update COPY paths) |
| `Gemfile` / `Gemfile.lock` | → split into `api/` and `search/` |
| `config.ru` | → `api/config.ru` (no change to contents) |
| `config.search.ru` | → `search/config.ru` (no change to contents) |
| `src/server.rb`, `src/vectorizer.rb` | → `api/src/` |
| `src/knn.rb`, `src/search_server.rb`, `src/knn_trainer.rb` | → `search/src/` |
| `resources/mcc_risk.json`, `normalization.json` | → `api/resources/` |
| `resources/references.json.gz` | → `search/resources/` |
| `test/server_unit_test.rb` | → `api/test/` |
| `docker-compose.yml` | update build contexts |

Internal relative paths in source files (`require_relative "../src/..."`, `File.expand_path("resources/...", __dir__)`) remain valid after the move.

---

## Verification

```bash
# Build both images from scratch
docker compose build --no-cache

# Start the stack
docker compose up -d

# Confirm API memory before load
docker compose exec api-1 grep VmRSS /proc/1/status

# Smoke test
curl http://localhost:9999/ready
curl -X POST http://localhost:9999/fraud-score -d @resources/example-payloads.json \
  -H "Content-Type: application/json"

# Confirm faiss/numo are NOT mapped into the API process
docker compose exec api-1 cat /proc/1/maps | grep -E 'faiss|narray'
# → should return nothing

# Run API unit tests
docker compose exec api-1 bundle exec ruby -Itest test/server_unit_test.rb
```
