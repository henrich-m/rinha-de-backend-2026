# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development

All development runs inside Docker — no local Ruby toolchain required.

**Stack:** Ruby 4, Puma (single-threaded Rack server), Oj (JSON), Faiss (HNSW index), Numo::NArray, nginx.

**Entry point:** `config.ru` at repo root — Puma loads it automatically. It requires `src/server.rb` and calls `run App` where `App` is a plain Rack lambda. Puma config is in `config/puma.rb` (1 thread, Unix socket bind).

**Dev commands:**

```bash
# First time — install gems and capture lockfile
docker compose -f docker-compose.dev.yml run --rm api bundle install
docker compose -f docker-compose.dev.yml run --rm api cat Gemfile.lock > Gemfile.lock

# Start server
docker compose -f docker-compose.dev.yml up -d

# Run a milestone test suite (server must be running)
docker compose -f docker-compose.dev.yml exec api bundle exec ruby -Itest test/m01_skeleton_test.rb

# Tail logs / stop
docker compose -f docker-compose.dev.yml logs -f api
docker compose -f docker-compose.dev.yml down
```

**Dockerfile.dev** — source is volume-mounted at `/app`; gems persist in `bundle_cache` volume at `/usr/local/bundle`. Rebuild only when `Gemfile` changes.


## Vectorizer

`src/vectorizer.rb` — `Vectorizer.new(normalization_path, mcc_risk_path)` then `vectorizer.vectorize(payload)` returns a 14-element `Float` array.

- Paths are passed explicitly so tests can run from the repo root without `__dir__` tricks.
- The `-1.0` sentinel at indices 5 and 6 must never be clamped — it signals no prior transaction.
- Weekday formula: `(Time#wday + 6) % 7` — converts Ruby's sun=0 to spec's mon=0, sun=6.
- All other values pass through `clamp(x)` = `[[x, 0.0].max, 1.0].min`.

**Dockerfile.api** — production image; source is COPYed in, not mounted.

## What this is

**Rinha de Backend 2026** — a backend competition where you build a fraud detection API using vector search. This repository contains the official challenge specification and reference data; your implementation goes in a separate repository.

## The challenge in one paragraph

For every incoming `POST /fraud-score` request, transform the transaction payload into a 14-dimensional normalized vector, find the 5 nearest neighbors in the reference dataset (`resources/references.json.gz`, 3,000,000 labeled vectors), compute `fraud_score = fraud_count / 5`, and return `approved = fraud_score < 0.6`.

## API contract

Two endpoints, both on port **9999**:

- `GET /ready` → `2xx` when ready to receive traffic.
- `POST /fraud-score` → `{ "approved": bool, "fraud_score": float }`.

Full request shape: `id`, `transaction.{amount, installments, requested_at}`, `customer.{avg_amount, tx_count_24h, known_merchants[]}`, `merchant.{id, mcc, avg_amount}`, `terminal.{is_online, card_present, km_from_home}`, `last_transaction: { timestamp, km_from_current } | null`.

## Vectorization — 14 dimensions in order

Uses `clamp(x)` = restrict to `[0.0, 1.0]`. Constants come from `resources/normalization.json` (max_amount=10000, max_installments=12, amount_vs_avg_ratio=10, max_minutes=1440, max_km=1000, max_tx_count_24h=20, max_merchant_avg_amount=10000).

| idx | dimension | formula |
|-----|-----------|---------|
| 0 | amount | `clamp(amount / 10000)` |
| 1 | installments | `clamp(installments / 12)` |
| 2 | amount_vs_avg | `clamp((amount / customer.avg_amount) / 10)` |
| 3 | hour_of_day | `hour(requested_at, UTC) / 23` |
| 4 | day_of_week | `weekday(requested_at) / 6` (mon=0, sun=6) |
| 5 | minutes_since_last_tx | `clamp(minutes / 1440)` or **`-1`** if `last_transaction: null` |
| 6 | km_from_last_tx | `clamp(km_from_current / 1000)` or **`-1`** if `last_transaction: null` |
| 7 | km_from_home | `clamp(km_from_home / 1000)` |
| 8 | tx_count_24h | `clamp(tx_count_24h / 20)` |
| 9 | is_online | `1` if online else `0` |
| 10 | card_present | `1` if card present else `0` |
| 11 | unknown_merchant | `1` if `merchant.id` NOT in `known_merchants` else `0` |
| 12 | mcc_risk | `mcc_risk.json[merchant.mcc]` (default `0.5`) |
| 13 | merchant_avg_amount | `clamp(merchant.avg_amount / 10000)` |

The `-1` sentinel at indices 5 and 6 is intentional and must not be clamped or replaced — it signals "no prior transaction" and naturally clusters similar transactions in vector space.

## Reference dataset

- `resources/references.json.gz` — 3M vectors, format: `[{ "vector": [...14 floats...], "label": "fraud"|"legit" }, ...]`. Decompress at startup.
- `resources/mcc_risk.json` — MCC → float risk score.
- `resources/normalization.json` — normalization constants.

These files **never change during the test** — pre-process, decompress, and index them at build time or container startup.

## Infrastructure constraints (hard rules)

- At least **1 load balancer + 2 API instances** (round-robin, no business logic in the LB).
- **Total resource budget: 1 CPU + 350 MB RAM** across all `docker-compose.yml` services.
- Port **9999** exposed on the load balancer.
- Images must be public and `linux/amd64` compatible.
- Network mode: `bridge` only (no `host`, no `privileged`).

## Submission structure

Your repository needs two branches:
- `main` — source code.
- `submission` — only `docker-compose.yml` and config files needed to run (no source code).

Trigger a test by opening a GitHub issue with `rinha/test` in the body. The Rinha Engine runs the test, posts results, and closes the issue.

## Scoring

`final_score = score_p99 + score_det` (each ranges −3000 to +3000).

- **score_p99**: `1000 · log₁₀(1000 / max(p99_ms, 1))`. Floor at −3000 if p99 > 2000ms.
- **score_det**: `1000 · log₁₀(1/ε) − 300 · log₁₀(1 + E)` where `E = 1·FP + 3·FN + 5·Err`. Floor at −3000 if failure rate > 15%.

Key implication: HTTP errors cost 5× more than false positives. If your backend can't decide, returning `approved: true, fraud_score: 0.0` is less damaging than a 5xx.

## Performance guidance

- Brute-force KNN over 3M × 14 dimensions is O(N·D) per query — likely too slow under load. Consider **HNSW** (pgvector, Qdrant, usearch), **IVF**, or **VP-Tree** for sub-linear search.
- Moving all startup preprocessing (decompress, build index) outside the hot path is the single biggest latency win.
- Target p99 ≤ 10ms for a meaningful latency score; below 1ms saturates at +3000.
