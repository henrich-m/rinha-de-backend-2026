# M14 — nginx → API via Unix Domain Socket

## Context

nginx currently proxies to api-1 and api-2 over Docker's bridge network TCP. Unix Domain Sockets bypass the TCP stack entirely — no checksumming, no connection state, no loopback routing — shaving latency on every proxied request.

---

## Why `falcon serve --bind unix://` doesn't work

`Falcon::Endpoint.parse` inherits `Async::HTTP::Endpoint.parse`, which always falls through to `IO::Endpoint.tcp(hostname, port)`. A `unix:` scheme URI yields an empty hostname → runtime error. The scheme is simply not handled.

---

## Correct approach: `falcon host` + `falcon.rb`

`Falcon::ProxyEndpoint.unix(path)` is Falcon's native Unix socket endpoint (used internally by `Falcon::Environment::Application` for IPC). It wraps `IO::Endpoint::UNIXEndpoint`.

`falcon host` reads a `falcon.rb` config file (DSL from `Async::Service::Loader`). Overriding `endpoint` in a `service` block is the supported production pattern.

---

## Files changed

| File | Change |
|------|--------|
| `api/falcon.rb` | New — `falcon host` config with `ProxyEndpoint.unix` |
| `docker-compose.yml` | `command: falcon host falcon.rb`; `SOCKET_PATH` env var; `depends_on` restored |
| `config/nginx.conf` | Upstream uses `unix:/run/api{1,2}/api.sock` |

---

## `api/falcon.rb`

```ruby
# frozen_string_literal: true

require "falcon/environment/rackup"
require "async/http/protocol"

service "api" do
  include Falcon::Environment::Rackup

  def rackup_path
    File.expand_path("config.ru", root)
  end

  def endpoint
    ::Falcon::ProxyEndpoint.unix(
      ENV.fetch("SOCKET_PATH", "/run/api/api.sock"),
      protocol: Async::HTTP::Protocol::HTTP1,
      scheme:   "http",
      authority: "localhost"
    )
  end
end
```

`protocol: HTTP1` is required — `ProxyEndpoint#protocol` reads from options; nil would crash `make_server`.

---

## Volume layout

```
api1_socket volume → /run/api  (api-1)  → api.sock created by Falcon
                   → /run/api1 (nginx)  → read by nginx as unix:/run/api1/api.sock

api2_socket volume → /run/api  (api-2)  → api.sock created by Falcon
                   → /run/api2 (nginx)  → read by nginx as unix:/run/api2/api.sock
```

---

## Verification

```bash
docker compose up -d --build

docker compose exec api-1 ls -la /run/api/
docker compose exec nginx ls -la /run/api1/ /run/api2/

curl http://localhost:9999/ready
curl -s -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d @resources/example-payloads.json | jq .

# No TCP to port 9292
docker compose exec nginx ss -tp 2>/dev/null | grep 9292
```
