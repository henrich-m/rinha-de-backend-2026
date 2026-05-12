# M20 — Remove Roda; serve with plain Rack lambda

## Context

Roda was the only web framework in the stack but was barely used: two routes, no plugins, no middleware. Replacing it with a plain Rack lambda eliminates a dependency while keeping the same interface that Falcon (via `Falcon::Environment::Rackup`) and the test suite (`rack-test`) already expect.

---

## Changes

| File | Change |
|------|--------|
| `api/src/server.rb` | Replaced `class App < Roda` with a Rack lambda `App = lambda do |env| … end` |
| `api/Gemfile` | Removed `gem "roda"` |
| `api/Gemfile.lock` | Removed `roda` spec, dependency, and checksum entries |

Files left untouched: `config.ru`, `falcon.rb`, `test/server_unit_test.rb`.

---

## How it works

The Rack contract is: a callable that receives `env` and returns `[status, headers, body_array]`. The new `App` lambda matches on `[REQUEST_METHOD, PATH_INFO]` and handles both routes directly:

```ruby
App = lambda do |env|
  case [env["REQUEST_METHOD"], env["PATH_INFO"]]
  when ["GET", "/ready"]
    begin
      KNN.ready? ? [200, {}, ["Ready"]] : [503, {}, ["Loading"]]
    rescue
      [503, {}, ["Unavailable"]]
    end
  when ["POST", "/fraud-score"]
    begin
      payload     = Oj.load(env["rack.input"].read, symbol_keys: false)
      vector      = VECTORIZER.vectorize(payload)
      labels      = KNN.search(vector, k: 5)
      fraud_count = labels.count { |v| v == 1 }
      fraud_score = fraud_count.to_f / 5
      body        = Oj.dump({ "approved" => fraud_score < 0.6, "fraud_score" => fraud_score })
      [200, { "Content-Type" => "application/json" }, [body]]
    rescue
      [200, { "Content-Type" => "application/json" },
            [Oj.dump({ "approved" => true, "fraud_score" => 0.0 })]]
    end
  else
    [404, {}, ["Not Found"]]
  end
end
```

`config.ru` still calls `run App` unchanged. Falcon loads it via `Falcon::Environment::Rackup`.

---

## Verification

```bash
docker compose run --rm api-1 bundle exec ruby -Itest test/server_unit_test.rb
# 11 runs, 18 assertions, 0 failures, 0 errors, 0 skips
```
