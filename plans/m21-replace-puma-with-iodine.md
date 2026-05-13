# Replace Puma with Iodine

## Context

Puma was chosen as a single-threaded Rack server after dropping Falcon. The goal was to reduce memory overhead further. Iodine (0.7.58) is a C-extension server with its own memory allocator — no heap fragmentation without jemalloc, no `nio4r` dependency. Result: 14 gems in lockfile (was 15 with Puma).

## Changes made

| File | Change |
|------|--------|
| `api/Gemfile` | `gem "puma"` → `gem "iodine"` |
| `api/Gemfile.lock` | Regenerated — 14 gems, `nio4r` removed |
| `api/config/puma.rb` | Deleted (iodine has no config file; all via CLI flags) |
| `Dockerfile` | CMD updated; `ENV NO_SSL=1` added |
| `docker-compose.yml` | Both `command:` lines updated; `NO_SSL: 1` added to env |

## Final state

### `api/Gemfile`
```ruby
gem "iodine"
```

### `Dockerfile` CMD
```dockerfile
ENV NO_SSL=1
CMD ["bundle", "exec", "iodine", "-b", "/run/api/api.sock", "-t", "1", "-w", "0"]
```

### `docker-compose.yml` command (both api-1 and api-2)
```yaml
command: bundle exec iodine -b /run/api/api.sock -t 1 -w 0
```

## Flag rationale

- `-t 1` — required: Faiss is not thread-safe; iodine defaults to multi-thread based on CPU count
- `-w 0` — single process, no forking; `-w 1` would spin up master+worker (2 processes), wasting memory
- `NO_SSL=1` — disables iodine's TLS setup; not needed behind nginx Unix socket
