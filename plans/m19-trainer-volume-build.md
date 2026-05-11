# M19 — Remove multi-stage build; train via volume-mounted container

## Context

Both `api/Dockerfile` and `search/Dockerfile` used two-stage builds where the `trainer` stage ran `knn_trainer.rb` at image-build time, then the `runtime` stage copied the artifacts via `COPY --from=trainer`. This had two problems:

1. Training is slow (3M vectors) and blocked every `docker compose build` — even when the model hadn't changed.
2. The trainer and runtime were coupled into one Dockerfile, making it hard to cache or parallelize.

The fix: extract training into a standalone container that mounts `./search` as a volume. Artifacts (`index.faiss`, `labels.bin`) are written to the host filesystem once, then COPY'd into the production images as regular files.

---

## Changes

| File | Change |
|------|--------|
| `search/Dockerfile.trainer` | New — trainer image with build tools and gems; source/output via volume |
| `api/Dockerfile` | Removed trainer stage; `COPY search/index.faiss search/labels.bin ./` replaces `COPY --from=trainer` |
| `search/Dockerfile` | Removed trainer stage; `COPY index.faiss labels.bin ./` replaces `COPY --from=trainer` |
| `docker-compose.yml` | Added `trainer` service with `profiles: [build]` and `./search:/app` volume |
| `Makefile` | `build` target now runs trainer first, then `docker compose build` |

---

## How it works

```
make build
  └─ docker compose --profile build run --rm trainer
       # builds trainer image (if not cached)
       # mounts ./search as /app
       # runs knn_trainer.rb → writes index.faiss + labels.bin to ./search/
  └─ docker compose build
       # api/Dockerfile: COPY search/index.faiss search/labels.bin ./
       # search/Dockerfile: COPY index.faiss labels.bin ./
```

The trainer image bakes in the gems (`/usr/local/bundle`) — mounting `./search` as `/app` at runtime provides the source files and receives the output without interfering with the installed gems.

---

## Verification

```bash
make build

docker compose up -d
curl http://localhost:9999/ready
```
