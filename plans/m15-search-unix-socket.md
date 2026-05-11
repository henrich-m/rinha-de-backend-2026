# M15 — search ↔ API via Unix Domain Socket

## Context

M14 moved nginx → api-1/api-2 communication to Unix Domain Sockets, bypassing the TCP stack. The api → search hop was still TCP (`http://search:9294`). This plan applies the same pattern to that leg: search binds to a UDS and api-1/api-2 connect to it via the same shared Docker volume.

---

## Why `falcon serve --bind unix://` doesn't work

Same root cause as M14: `Falcon::Endpoint.parse` falls through to TCP for unrecognised schemes. The fix is the same: use `falcon host` + a `falcon.rb` config file with `ProxyEndpoint.unix`.

---

## Files changed

| File | Change |
|------|--------|
| `search/falcon.rb` | New — `falcon host` config binding to `SOCKET_PATH` via `ProxyEndpoint.unix` |
| `search/Dockerfile` | CMD → `falcon host falcon.rb` |
| `api/config.ru` | `SEARCH_URL` → `SEARCH_SOCKET` constant |
| `api/src/server.rb` | Client uses `Falcon::ProxyEndpoint.unix(SEARCH_SOCKET)` instead of `Async::HTTP::Endpoint.parse` |
| `docker-compose.yml` | New `search_socket` volume shared by search + api-1 + api-2; env var `SEARCH_URL` → `SEARCH_SOCKET`; healthcheck uses `--unix-socket` |

---

## `search/falcon.rb`

```ruby
# frozen_string_literal: true

require "falcon/environment/server"
require "falcon/environment/rackup"
require "async/http/protocol"

service "search" do
  include Falcon::Environment::Server
  include Falcon::Environment::Rackup

  count 1

  endpoint do
    ::Falcon::ProxyEndpoint.unix(
      ENV.fetch("SOCKET_PATH", "/run/search/search.sock"),
      protocol: Async::HTTP::Protocol::HTTP1,
      scheme:   "http",
      authority: "localhost"
    )
  end
end
```

## Client side (`api/src/server.rb`)

`Falcon::ProxyEndpoint.unix` works for client connections too — `Async::HTTP::Client` calls `endpoint.connect` internally, which delegates to the underlying `IO::Endpoint::UNIXEndpoint`. The `protocol`, `scheme`, and `authority` options are required so the client can negotiate HTTP correctly.

```ruby
require "falcon/proxy_endpoint"
require "async/http/protocol"

def self.client
  @client ||= Async::HTTP::Client.new(
    Falcon::ProxyEndpoint.unix(
      SEARCH_SOCKET,
      protocol: Async::HTTP::Protocol::HTTP1,
      scheme:   "http",
      authority: "localhost"
    )
  )
end
```

## Volume layout

```
search_socket volume → /run/search  (search)   → search.sock created by Falcon
                     → /run/search  (api-1)     → read by API client
                     → /run/search  (api-2)     → read by API client
```

---

## Verification

```bash
docker compose build search
docker compose up -d

# Socket exists
docker compose exec search ls -la /run/search/

# Healthcheck passes
docker compose ps search

# End-to-end
curl http://localhost:9999/ready
curl -s -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d @resources/example-payloads.json | jq .

# No TCP to port 9294
docker compose exec api-1 ss -tp 2>/dev/null | grep 9294
```
