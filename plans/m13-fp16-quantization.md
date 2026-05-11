# M13 — Replace IndexIVFFlat with IndexIVFScalarQuantizer (fp16)

## Context

`IndexIVFFlat` stores every vector in raw float32: 3M × 14 × 4 bytes = **168MB** resident at runtime. Switching to `IndexIVFScalarQuantizer` with `QT_fp16` halves that to **84MB** with virtually no accuracy loss — all vector components are either `-1.0` (sentinel) or clamped to `[0.0, 1.0]`, a range where float16 retains ~3 decimal digits of precision.

`knn.rb` uses `Faiss::Index.load` which is index-type agnostic — it deserializes whatever type was saved. No runtime code changes needed.

---

## Change

**Only `search/src/knn_trainer.rb` line 25 changes:**

```ruby
# Before
index = Faiss::IndexIVFFlat.new(quantizer, DIM, NLIST, :l2)

# After
index = Faiss::IndexIVFScalarQuantizer.new(quantizer, DIM, NLIST, :qt_fp16)
```

Note: the Ruby bindings default the metric to L2, so the 5th argument is omitted.

Everything else stays identical: `index.train(matrix)`, `index.add(matrix)`, `index.save(INDEX_PATH)`, labels writing — all unchanged.

---

## Files changed

| File | Change |
|------|--------|
| `search/src/knn_trainer.rb` | Line 25: `IndexIVFFlat` → `IndexIVFScalarQuantizer` with `:qt_fp16` |
| `search/src/knn.rb` | None — `Faiss::Index.load` is type-agnostic |
| `search/Dockerfile` | None — rebuild triggers trainer automatically |

---

## Verification

```bash
# Rebuild search image (trainer runs during build)
docker compose build --no-cache search

# Start the stack
docker compose up -d

# Confirm search is healthy
curl http://localhost:9999/ready

# Smoke test
curl -s -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d @resources/example-payloads.json | jq .

# Check search container RSS — expect ~84MB lower than IndexIVFFlat
docker compose exec search grep VmRSS /proc/1/status

# Trigger a Rinha test run to validate score_det hasn't regressed
# (open a GitHub issue with rinha/test in the body)
```
