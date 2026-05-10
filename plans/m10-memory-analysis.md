# M10 — Memory Analysis: API Container (70MB → 30MB target)

## Context

The API container currently consumes ~70MB under load; the target is ≤30MB across both `api-1` and `api-2` within the 350MB total budget. The API is intentionally lightweight (no KNN index), but the full `ruby:4` image + YJIT + Falcon + the search gem bundle are the prime suspects. This plan produces measurements, not fixes — the output feeds a second plan.

**API requires at runtime:** `roda`, `oj`, `async-http`, `falcon`, `src/vectorizer.rb`  
**Installed but NOT required:** `faiss`, `numo-narray` (needed only by the search service)  
**YJIT:** enabled via `RUBY_YJIT_ENABLE=1` — grows under load  
**Allocator:** `jemalloc` via `LD_PRELOAD`  

---

## Step 1 — Baseline RSS before any requests

Goal: separate Ruby startup cost from load-driven growth.

```bash
# Start the stack
docker compose up -d

# Get RSS from the API process
docker compose exec api-1 cat /proc/1/status | grep -E 'VmRSS|VmPSS|VmSwap'

# Or poll every 2s while idle
docker compose exec api-1 sh -c 'while true; do grep VmRSS /proc/1/status; sleep 2; done'
```

**What to record:** `VmRSS` (total resident), `VmPSS` (proportional, deducts shared pages), `VmSwap`.

---

## Step 2 — Detailed smaps breakdown (private vs shared)

Goal: identify how much of the RSS is shared library code (shared by both API instances via CoW) vs private heap.

```bash
docker compose exec api-1 cat /proc/1/smaps_rollup
```

Key fields:
- `Private_Dirty` — memory only this process owns (actual cost)
- `Shared_Clean` — read-only shared pages (Ruby stdlib, gem .so files)
- `Heap` — native malloc heap

Also check whether `libfaiss` or `numo` `.so` files appear in the maps even though they're not `require`d:

```bash
docker compose exec api-1 cat /proc/1/maps | grep -E 'faiss|narray'
```

If they show up → the gem loads its native extension at `bundle exec` time, not at `require` time. This would be a significant finding.

---

## Step 3 — YJIT code cache size

Goal: quantify how much memory YJIT consumes under load.

Add a temporary diagnostic endpoint in `src/server.rb`:

```ruby
r.get "debug-mem" do
  response["Content-Type"] = "application/json"
  stats = RubyVM::YJIT.runtime_stats rescue {}
  gc    = GC.stat
  obj   = ObjectSpace.count_objects
  Oj.dump({ yjit: stats, gc: gc, objects: obj })
end
```

Then hit it before load and after load:

```bash
# Before load
curl http://localhost:9999/debug-mem | jq .yjit.code_region_size

# Run load
wrk -t4 -c50 -d30s -s post.lua http://localhost:9999/fraud-score

# After load
curl http://localhost:9999/debug-mem | jq '{yjit_code: .yjit.code_region_size, heap_pages: .gc.heap_allocated_pages, live_objects: .gc.heap_live_slots}'
```

**What to record:** `code_region_size` (YJIT compiled code bytes), `heap_allocated_pages` × 16KB = Ruby heap size, `heap_live_slots`.

---

## Step 4 — Which gems are actually loaded

Goal: confirm whether `faiss`/`numo-narray` are loaded into the API process.

```bash
docker compose exec api-1 bundle exec ruby -e '
  require_relative "config.ru"
  puts $LOADED_FEATURES.grep(/faiss|narray|numo/)
  puts "---"
  puts $LOADED_FEATURES.count
  puts $LOADED_FEATURES.grep(/falcon|async|roda|oj/).sort
'
```

If `faiss` or `numo` appear → they are being auto-required by Falcon or Bundler at boot — potentially ~10-20MB of native extension memory wasted.

---

## Step 5 — Object allocation profiling under load

Goal: identify which Ruby classes allocate the most per request.

Add `memory_profiler` temporarily to Gemfile (`:development` group) and create:

```ruby
# scripts/profile_request.rb
require "memory_profiler"
require_relative "../config.ru"

SAMPLE_PAYLOAD = File.read("test/fixtures/sample_request.json")

report = MemoryProfiler.report do
  1000.times do
    payload = Oj.load(SAMPLE_PAYLOAD, symbol_keys: false)
    vector  = VECTORIZER.vectorize(payload)
    Oj.dump({ "approved" => true, "fraud_score" => 0.2 })
  end
end

report.pretty_print(to_file: "/tmp/mem_profile.txt", scale_bytes: true)
```

```bash
docker compose exec api-1 bundle exec ruby scripts/profile_request.rb
docker compose exec api-1 cat /tmp/mem_profile.txt | head -60
```

**What to look for:** Top allocating gems/files, largest retained objects, String vs Array vs Hash ratios.

---

## Step 6 — Docker stats under sustained load

Goal: capture peak RSS during actual benchmark (mirrors what the grader sees).

```bash
# Terminal 1
docker stats api-1 api-2 --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"

# Terminal 2
wrk -t4 -c50 -d60s -s post.lua http://localhost:9999/fraud-score
```

Record peak memory for each container and note whether it stabilizes or grows continuously (growing = YJIT compiling new paths or a leak).

---

## Step 7 — Compare with YJIT disabled

Goal: isolate YJIT's exact memory contribution.

```bash
docker compose exec api-1 env RUBY_YJIT_ENABLE=0 bundle exec falcon serve \
  --bind http://0.0.0.0:9292 --count 1
```

Re-run the load benchmark and compare peak RSS vs Step 6.

---

## Expected output

After running all steps, fill in this table:

| Component | Memory contribution |
|-----------|---------------------|
| Ruby interpreter + stdlib | ? |
| Gem shared libraries (.so) | ? |
| `faiss`/`numo` if accidentally loaded | ? |
| YJIT code cache | ? |
| Ruby heap (live objects) | ? |
| Falcon/async buffers | residual |

The component with the highest **private dirty** contribution is the first target for the fix plan.

---

## Files relevant to this analysis

- `Dockerfile.api` — base image, YJIT env var, jemalloc, gem install
- `Gemfile` — `faiss` + `numo-narray` present even though API doesn't use them
- `config.ru` — boot sequence (does NOT call `Bundler.require`)
- `src/server.rb` — only requires: `roda`, `oj`, `async/http/client`, `async/http/endpoint`
- `src/vectorizer.rb` — only loads two small JSON files at startup
- `docker-compose.yml` — resource limits commented out; `api-1`/`api-2` have no cap yet
