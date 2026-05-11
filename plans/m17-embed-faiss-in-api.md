# M17 — Embed FAISS in the API, remove the search service

## Context

The previous architecture routed every request through two hops: API → Unix socket → search service → FAISS. The search service ran a single Falcon event loop, so FAISS (a blocking C call) serialized all queries — even under load from 2 API instances.

Removing the search service and loading FAISS directly inside each API instance gives true parallel searches for free: api-1 and api-2 are separate OS processes with independent Ruby runtimes, so their FAISS calls run in parallel with no GIL or synchronization overhead. The IPC round-trip (~0.1–0.5ms) is also eliminated.

**Memory tradeoff:** 2 × 84MB FAISS = 168MB (vs 84MB shared). The removed search service frees its 200MB allocation, so the budget holds.

New per-service limits:
- api-1: 165MB / 0.425 CPU
- api-2: 165MB / 0.425 CPU
- nginx:  10MB / 0.15 CPU
- Total: 340MB / 1.00 CPU ✓

---

## Changes

### `api/Gemfile`
Added `faiss` and `numo-narray`.

### `api/src/knn.rb` *(new file)*
`Knn` class copied verbatim from `search/src/knn.rb`.

### `api/config.ru`
Loads `KNN` alongside `VECTORIZER`; dropped `SEARCH_SOCKET`.

### `api/src/server.rb`
Removed the `Search` module and async HTTP client entirely. `/ready` checks `KNN.ready?`; `POST /fraud-score` calls `KNN.search` directly.

### `api/Dockerfile`
Two-stage build — trainer stage installs native deps (cmake, g++, libblas-dev, liblapack-dev), runs `knn_trainer.rb` to produce `index.faiss` + `labels.bin`; runtime stage copies the baked index in. Build context must be repo root (`.`) so the trainer can reach `search/resources/references.json.gz` and `search/src/knn_trainer.rb` without duplicating the file.

### `docker-compose.yml`
- Removed `search` service and `search_socket` volume.
- Removed `depends_on: search` and `SEARCH_SOCKET` env from api-1 and api-2.
- Build context changed to `.`, dockerfile to `api/Dockerfile`.
- Added `KNN_NPROBE: "10"` to api-1 and api-2.
- Updated resource limits (api: 165MB / 0.425 CPU each, nginx: 10MB / 0.15 CPU).

---

## Files changed

| File | Change |
|------|--------|
| `api/Gemfile` | Add `faiss`, `numo-narray` |
| `api/Gemfile.lock` | Regenerate after gem additions |
| `api/src/knn.rb` | New — copy of `search/src/knn.rb` |
| `api/config.ru` | Load `KNN`, drop `SEARCH_SOCKET` |
| `api/src/server.rb` | Remove `Search` module, call `KNN` directly |
| `api/Dockerfile` | Add trainer stage, native deps, new CMD |
| `docker-compose.yml` | Remove search service/volume, update limits/context |

---

## Verification

```bash
# Regenerate Gemfile.lock (faiss has native extensions)
docker compose -f docker-compose.dev.yml run --rm api bundle install
docker compose -f docker-compose.dev.yml run --rm api cat Gemfile.lock > api/Gemfile.lock

# Build API image (trainer stage runs knn_trainer.rb during build)
docker compose build --no-cache api-1

# Start stack
docker compose up -d

# Both APIs should be healthy
curl http://localhost:9999/ready

# Smoke test
curl -s -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d @resources/example-payloads.json | jq .

# Memory check — each API should be ~130–150MB RSS
docker compose exec api-1 grep VmRSS /proc/1/status
docker compose exec api-2 grep VmRSS /proc/1/status

# Trigger Rinha test (open GitHub issue with rinha/test in body)
```
