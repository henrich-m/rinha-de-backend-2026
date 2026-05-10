# M12 — Replace JSON with binary protocol on the API ↔ Search hop

## Context

The internal `/knn` call between the API and Search services currently uses HTTP + JSON. Each request serializes a 14-float vector to ~200 bytes of JSON text; the response wraps 5 labels in another ~30 bytes of JSON. This creates transient String allocations on every request and drags `oj` into the Search container despite the search service having no client-facing JSON to handle.

Switching to a fixed-width binary format (`Array#pack` / `String#unpack`) eliminates those allocations, shrinks each internal message from ~230 bytes to 61 bytes, and lets us drop `oj` from the Search Gemfile entirely.

**This is a latency optimization first.** Steady-state memory savings are small (~1-2MB from evicting the oj native extension from the search process). The primary benefit is lower CPU per request and reduced GC pressure under load.

**Depends on M11** (separate Gemfiles). File paths below reflect the post-M11 layout.

---

## Binary protocol design

```
Request  POST /knn  →  14 × float32 little-endian  =  56 bytes
Response            ←   5 × uint8   (0 or 1)        =   5 bytes
```

Ruby encoding:
```ruby
# API side — send
vector.pack("e14")          # 14 little-endian single-precision floats

# Search side — receive
r.body.read.unpack("e14")   # → Array of 14 Floats

# Search side — send
results.pack("C5")          # 5 unsigned bytes (values are 0 or 1)

# API side — receive
resp.read.unpack("C5")      # → Array of 5 Integers
```

No framing, no separator, no length prefix needed — sizes are fixed by the protocol contract.

---

## Changes

### 1 — `search/src/search_server.rb`

Remove `oj`. Change the `/knn` handler to read raw bytes and write raw bytes.

**Before:**
```ruby
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
      body    = Oj.load(r.body.read, symbol_keys: false)
      results = KNN.search(body["vector"], k: body.fetch("k", 5))
      Oj.dump({ "results" => results })
    end
  end
end
```

**After:**
```ruby
# frozen_string_literal: true
require "roda"

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
      vector = r.body.read.unpack("e14")
      results = KNN.search(vector, k: 5)
      response["Content-Type"] = "application/octet-stream"
      results.pack("C5")
    end
  end
end
```

### 2 — `api/src/server.rb`

Change `Search.knn` to pack/unpack binary. Remove the `Oj.dump`/`Oj.load` call on the internal hop. Update the result variable since `knn` now returns the array directly.

**Before:**
```ruby
def self.knn(vector)
  body = Oj.dump({ "vector" => vector, "k" => 5 })
  resp = client.post("/knn",
    [["content-type", "application/json"]],
    [body]
  )
  Oj.load(resp.read, symbol_keys: false)
end

# ...in the route:
data        = Search.knn(vector)
fraud_count = data["results"].count { |v| v == 1 }
```

**After:**
```ruby
def self.knn(vector)
  resp = client.post("/knn",
    [["content-type", "application/octet-stream"]],
    [vector.pack("e14")]
  )
  resp.read.unpack("C5")
end

# ...in the route:
labels      = Search.knn(vector)
fraud_count = labels.count { |v| v == 1 }
```

### 3 — `search/Gemfile`

Remove `oj` — the search service no longer uses it.

**Before:**
```ruby
gem "falcon"
gem "io-endpoint"
gem "roda"
gem "oj"
gem "numo-narray"
gem "faiss"
```

**After:**
```ruby
gem "falcon"
gem "io-endpoint"
gem "roda"
gem "numo-narray"
gem "faiss"
```

Then regenerate `search/Gemfile.lock`:
```bash
docker run --rm -v $(pwd)/search:/app -w /app \
  ruby:4 bash -c "apt-get update -qq && apt-get install -y cmake g++ libblas-dev liblapack-dev && bundle install"
```

---

## Files changed

| File | Change |
|------|--------|
| `search/src/search_server.rb` | Remove oj; binary body in/out on `/knn` |
| `api/src/server.rb` | Pack vector; unpack response; remove oj from internal call |
| `search/Gemfile` | Remove `oj` |
| `search/Gemfile.lock` | Regenerate |

`api/Gemfile` is **unchanged** — `oj` stays because the API still parses client JSON payloads and serializes client responses.

`search/src/knn.rb` is **unchanged** — `Knn#search` already accepts an Array of Floats and returns an Array of Integers.

---

## Verification

```bash
# Rebuild search image
docker compose build search

# Start the stack
docker compose up -d

# Smoke test
curl http://localhost:9999/ready
curl -s -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d @resources/example-payloads.json | jq .

# Confirm oj is gone from search process
docker compose exec search grep -r "oj" /usr/local/bundle/specifications/
# → should return nothing

# Run unit tests
docker compose exec api-1 bundle exec ruby -Itest test/server_unit_test.rb

# Load test — confirm latency improves
wrk -t4 -c50 -d30s -s post.lua http://localhost:9999/fraud-score
# Compare p99 against pre-M12 baseline
```
