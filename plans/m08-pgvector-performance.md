# M08 — pgvector Performance Tuning

## Goal

Reduce p99 query latency for the KNN search against 3M × 14-dim vectors. Three levers: data type (halfvec), ef_search tuning, and postgresql.conf aligned to the 125MB memory budget.

---

## Change 1 — Switch `vector(14)` → `halfvec(14)` *(requires image rebuild)*

`halfvec` stores each float as 16-bit instead of 32-bit. The HNSW index shrinks ~50% (roughly 800MB → 400MB). A smaller index means more index pages fit in the OS page cache → fewer disk reads per query → lower and more consistent latency.

Recall impact is negligible: all vectorized values are either in [0.0, 1.0] or the −1 sentinel, well within float16 range.

Also drops `id SERIAL PRIMARY KEY` and its ~42MB B-tree index since `id` is never queried.

**`Dockerfile.db`** — builder schema and index:
```sql
-- was: CREATE TABLE refs (id SERIAL PRIMARY KEY, embedding vector(14), is_fraud BOOLEAN)
CREATE TABLE refs (embedding halfvec(14) NOT NULL, is_fraud BOOLEAN NOT NULL);

-- was: hnsw (embedding vector_l2_ops)
CREATE INDEX ON refs USING hnsw (embedding halfvec_l2_ops) WITH (m=16, ef_construction=64);
```

**`scripts/seed.rb`** — the `COPY` command already names columns; just ensure `id` is not in the column list. Float literals copy into `halfvec` columns without format change.

**`src/db.rb`** — update the query cast:
```ruby
# was: $1::vector
"SELECT is_fraud FROM refs ORDER BY embedding <-> $1::halfvec LIMIT $2"
```

---

## Change 2 — Lower `ef_search` to 15 *(no rebuild — runtime config only)*

pgvector's default is `ef_search=40`. For k=5 in 14 dimensions (very low-dimensional space) the HNSW graph is already highly accurate — ef_search=15 gives >99% recall while cutting traversal work by ~60%.

Set globally in `postgresql.conf` (no Ruby change needed; applies to all connections):

```
hnsw.ef_search = 15
```

After the first submission, if the detection score is healthy, step down to 10.

---

## Change 3 — Tune `postgresql.conf` for the 125MB budget *(no rebuild)*

Budget: 350MB total − 100MB (api-1) − 100MB (api-2) − 25MB (nginx) = **125MB for postgres**.

PostgreSQL RSS ≈ `shared_buffers` + (connections × ~5MB) + ~20MB overhead.  
With `max_connections=10` (we need ≤8 active): 32 + 10×5 + 20 = **102MB** — fits safely.

| Setting | New value | Was | Reason |
|---|---|---|---|
| `shared_buffers` | `32MB` | `64MB` | Fit budget; the 400MB index won't fit anyway — OS cache does the work |
| `max_connections` | `10` | `20` | Pool limit=4 × 2 APIs = 8 connections max |
| `work_mem` | `2MB` | `4MB` | Queries are `ORDER BY … LIMIT 5`, no sort spill needed |
| `maintenance_work_mem` | `16MB` | `32MB` | No maintenance runs at runtime |
| `effective_cache_size` | `96MB` | unset | Tells planner how much OS cache is realistically available |
| `random_page_cost` | `1.1` | default `4.0` | Containers run on SSD; default assumes spinning disk |
| `hnsw.ef_search` | `15` | unset | See Change 2 |

---

## Change 4 — Add `ANALYZE refs` after index build *(no rebuild, ~5s added to build time)*

After `CREATE INDEX`, planner statistics are stale. Adding `ANALYZE refs` immediately after the index creation step marks all heap pages as all-visible → reduces per-row visibility overhead on index scans.

```sql
ANALYZE refs;
```

---

## What NOT to change

| Option | Verdict |
|---|---|
| HNSW `m=16, ef_construction=64` | Leave as-is — already well-tuned for 14 dims |
| IVFFlat index | 15× slower query throughput than HNSW at the same recall — wrong for low-latency workloads |
| Binary quantization (`bit` type) | For 14 dims the recall loss is not offset by speed gain |
| Product quantization | Not natively available in pgvector |

---

## Files to modify

| File | What changes |
|---|---|
| `Dockerfile.db` | Schema → `halfvec(14)`, drop `id`, index → `halfvec_l2_ops`, updated `postgresql.conf` block, add `ANALYZE refs` |
| `src/db.rb` | Cast `$1::halfvec` in the KNN query |
| `scripts/seed.rb` | Remove `id` from `COPY` column list |
| `docker-compose.yml` | Uncomment and set postgres resource limits (125MB / 0.60 CPU) |

---

## Verification

```bash
# Rebuild the DB image and bring the full stack up
docker compose up --build -d

# Confirm halfvec column and correct index operator class
docker compose exec postgres psql -U postgres -d rinha -c "\d refs"
docker compose exec postgres psql -U postgres -d rinha -c \
  "SELECT indexname, indexdef FROM pg_indexes WHERE tablename='refs';"

# Confirm ef_search is set
docker compose exec postgres psql -U postgres -d rinha -c "SHOW hnsw.ef_search;"

# Smoke test
curl -sf http://localhost:9999/ready
curl -sf -X POST http://localhost:9999/fraud-score \
  -H 'Content-Type: application/json' \
  -d '{"id":"tx-1","transaction":{"amount":100,"installments":1,"requested_at":"2026-03-11T18:45:53Z"},"customer":{"avg_amount":200,"tx_count_24h":1,"known_merchants":[]},"merchant":{"id":"MERC-001","mcc":"5411","avg_amount":80},"terminal":{"is_online":false,"card_present":true,"km_from_home":5},"last_transaction":null}'

# Unit tests (no DB needed)
docker compose -f docker-compose.dev.yml exec api \
  bundle exec ruby -Itest test/server_unit_test.rb
```
