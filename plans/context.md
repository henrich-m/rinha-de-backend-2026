# Rinha de Backend 2026 — Project Context

## Challenge summary

Build a fraud detection API that runs k-NN (k=5, Euclidean) over 3,000,000 labeled 14-dimensional vectors and returns `{ approved, fraud_score }` for every incoming card transaction. Approved = fraud_score < 0.6.

## Stack

- **Language**: Ruby 4
- **Web server**: Falcon (async fiber-based)
- **Router**: Roda
- **JSON**: oj gem
- **Database**: PostgreSQL 16 + pgvector extension
- **Vector index**: HNSW (`vector_l2_ops`) pre-built into the postgres Docker image
- **DB client**: async-postgres gem (fiber-scheduler-aware wrapper around `pg` — required for Falcon so fibers don't block each other on queries)
- **Connection pooler**: PgBouncer (transaction mode, sits between API and postgres)
- **Load balancer**: nginx (round-robin, no business logic, communicates with API instances via Unix sockets)

## Why pre-baked postgres image

The reference dataset (3M × 14 float32 vectors) is loaded into postgres and the HNSW index is built **at Docker image build time** via a multi-stage Dockerfile. At runtime the postgres container starts with data already present — no seed delay, `/ready` returns 200 within seconds of postgres accepting connections.

## Development workflow

No local Ruby toolchain required — all development runs inside Docker.

```bash
# Install gems (first time)
docker compose -f docker-compose.dev.yml run --rm api bundle install

# Start dev server
docker compose -f docker-compose.dev.yml up -d

# Run a milestone's test suite
docker compose -f docker-compose.dev.yml exec api bundle exec ruby -Itest test/mXX_test.rb

# Stop
docker compose -f docker-compose.dev.yml down
```

## Repository layout (main branch)

```
src/
  server.rb          # Falcon/Roda entry point
  vectorizer.rb      # payload → 14-dim float array
  db.rb              # async-postgres client + query helpers
scripts/
  seed.rb            # bulk-loads references.json.gz into postgres via COPY
test/
  m01_skeleton_test.rb
  m02_vectorization_test.rb
  ... (one file per milestone)
config/
  nginx.conf
  pgbouncer.ini
Gemfile
Dockerfile.dev       # Ruby 4 dev image (source is volume-mounted)
Dockerfile.api       # Ruby 4 production API image (source is COPYed)
Dockerfile.db        # Multi-stage: builder loads data, final copies pgdata
docker-compose.dev.yml
```

## Submission branch layout

```
docker-compose.yml
nginx.conf
info.json
```

## Resource budget

Total across all docker-compose services: **1 CPU + 350 MB RAM**. Suggested split:

| Service    | CPUs  | Memory |
|------------|-------|--------|
| nginx      | 0.05  | 20 MB  |
| pgbouncer  | 0.05  | 10 MB  |
| postgres   | 0.35  | 160 MB |
| api-1      | 0.275 | 80 MB  |
| api-2      | 0.275 | 80 MB  |
| **Total**  | **1.0** | **350 MB** |

PostgreSQL should be tuned for the memory limit: `shared_buffers=64MB`, `work_mem=4MB`, `maintenance_work_mem=32MB`, `max_connections=20` (PgBouncer multiplexes, so postgres needs few direct connections).

## Milestone index

| # | File | Goal |
|---|------|------|
| 1 | [m01-skeleton.md](m01-skeleton.md) | Ruby HTTP server on :9999 with `/ready` 200 and `/fraud-score` stub |
| 2 | [m02-vectorization.md](m02-vectorization.md) | Correct 14-dim normalized vector from any valid payload |
| 3 | [m03-postgres-setup.md](m03-postgres-setup.md) | postgres+pgvector schema + seed script loads 3M vectors locally |
| 4 | [m04-knn-scoring.md](m04-knn-scoring.md) | Correct `fraud_score` via pgvector `<->` nearest-neighbor query |
| 5 | [m05-baked-image.md](m05-baked-image.md) | Multi-stage Dockerfile pre-bakes data + HNSW index; sub-50ms p99 |
| 6 | [m06-containerization.md](m06-containerization.md) | docker-compose: nginx + pre-baked postgres + 2 API instances within budget |
| 7 | [m07-submission.md](m07-submission.md) | Submission-ready: k6 preview test passes with score > 0 |
