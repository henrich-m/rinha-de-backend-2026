# M18 — qt_8bit + nprobe=64 (memory vs precision experiment)

## Context

Each API instance consumes ~190MB after embedding FAISS in M17. The target is 165MB. Memory analysis ruled out YJIT (12KB), jemalloc dirty pages (52KB retained), and Ruby heap (1.2MB) as levers. The only reducible component is the FAISS index:

| Component | Size |
|-----------|------|
| FAISS fp16 codes | 84MB |
| FAISS IVF IDs | 24MB |
| Labels `Numo::Int8` | 3MB |
| Shared libs + Ruby | ~79MB |
| **Total** | **~190MB** |

`qt_8bit` alone (nprobe=11) degraded precision from 0.02 → 0.1 error. This experiment tests whether that regression is a **recall problem** (fixable by increasing nprobe) or a **quantization error** (fundamental to 8-bit).

With `nprobe=64` the IVF search covers 64/8192 ≈ 0.78% of the index per query (vs 0.13% at nprobe=11), giving the quantizer a much better chance to find the true nearest neighbors.

**Memory if successful:** `qt_8bit` codes = 42MB + 24MB IDs = 66MB FAISS → ~148MB per API (well under 165MB).

---

## Changes

| File | Change |
|------|--------|
| `search/src/knn_trainer.rb` | Line 25: `:qt_fp16` → `:qt_8bit` |
| `docker-compose.yml` | `KNN_NPROBE: "64"` in api-1 and api-2 (was `"11"`) |

---

## Interpretation

| Rinha result | Meaning | Next step |
|--------------|---------|-----------|
| Precision ~0.02–0.04 | Recall was the bottleneck; tuning works | Ship it |
| Precision stays ~0.1 | Quantization error dominates; nprobe can't fix it | Try `qt_6bit` |

---

## Verification

```bash
# Rebuild (trainer must re-run to produce 8-bit index)
docker compose build --no-cache api-1

# Start stack
docker compose up -d

# Smoke test
curl -s -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d @resources/example-payloads.json | jq .

# Memory check — expect ~148MB RSS vs 190MB before
docker compose exec api-1 grep VmRSS /proc/1/status

# Trigger Rinha test (open GitHub issue with rinha/test in body)
```

## Revert

```bash
# knn_trainer.rb line 25: :qt_8bit → :qt_fp16
# docker-compose.yml: KNN_NPROBE: "64" → "11"
```
