# Conveyance — a Zig backend for Transmission

**Date:** 2026-05-24
**Status:** Design approved; ready for implementation planning.

## 1. Summary

Conveyance is a reimplementation of Transmission's **core BitTorrent engine** in Zig,
packaged as a daemon that is a **drop-in replacement for `transmission-daemon`**. It speaks
the same JSON-RPC/HTTP protocol, so the existing web UI, `transmission-remote`, and GUIs in
remote-session mode connect to it unchanged.

It exists to fix two specific shortcomings of the current daemon:

1. **Blocking startup.** `tr_sessionLoadTorrents` (libtransmission/session.cc:1567) posts
   `session_load_torrents` to the session thread and then blocks on `loaded_future.get()`. The
   daemon does not become useful until *every* `.torrent` has been read, parsed, and had its
   `.resume` state loaded — sequentially. Conveyance loads torrents **concurrently** and makes
   **each torrent interactive the instant it is scanned**, with the RPC server accepting clients
   before any torrent has loaded.
2. **Unstructured logging.** Transmission logs free-text lines at a single global level.
   Conveyance emits **structured records** with **per-context fields** (torrent, subsystem, peer,
   piece) via a **non-blocking** writer, so logs are greppable, filterable, and never stall the
   hot path.

### Non-goals (this spec)

No GUI of our own. No DHT, LPD, PEX, encryption (MSE/PE), µTP, webseeds, magnet-only torrents,
UPnP/NAT-PMP, or blocklists. TCP peers + `.torrent` files + HTTP/UDP trackers only. Linux-first.
These are deferred to later sub-projects (see §11).

## 2. Scope of the first deliverable

A **minimal end-to-end download**: the daemon starts, streams its existing torrents into an
interactive state, accepts RPC, announces to trackers, connects to TCP peers, and downloads a
single torrent to completion — with the concurrency and logging improvements as first-class
properties, not afterthoughts.

## 3. Runtime & threading model (hybrid reactor)

**Core invariant: all torrent/peer state is mutated on exactly one thread (the session-owner
thread). Everything else communicates by message.** This mirrors Transmission's
`run_in_session_thread` discipline, made explicit, and is what keeps the concurrency tractable.

| Thread | Owns | Responsibility |
|--------|------|---------------|
| **Net reactor** | sockets, io_uring ring | All non-blocking socket I/O: peer TCP, tracker UDP/HTTP, RPC HTTP listener. Stateless peer-wire framing. Reads bytes → posts semantic events to session thread; writes bytes on command. Owns no torrent state. Accepts RPC connections immediately at startup. |
| **Session-owner** | torrent registry, counters, timers | The single mutator. Drains one MPSC command/event queue fed by loader, trackers, peers, RPC, disk. Runs a periodic tick (announce intervals, choke rotation, stats, periodic resume persist). |
| **Loader pool** (`std.Thread.Pool`) | — | One job per `.torrent` at startup: parse metainfo + import `.resume` → post `TorrentLoaded`. Reused for `torrent-add`. |
| **Disk/hash pool** | — | Piece SHA-1 verification, block read/write, file preallocation. Posts completions to session thread. (May share the loader pool; kept conceptually separate.) |
| **Logger** | log sink | Drains a bounded MPSC ring of records, formats, writes. Producers never block; full-queue → bump dropped-counter. |

Inter-thread transport for v1: mutex + condvar guarded MPSC queues (correct first; lock-free
optimization later). The reactor uses `std.os.linux.IoUring` with an epoll fallback path.

## 4. Components

Each is an independently-testable unit with a narrow interface.

| Module | Responsibility | Runs on |
|--------|---------------|---------|
| `bencode` | streaming decode/encode, zero-copy slices into input | pure |
| `metainfo` | parse `.torrent`; infohash (SHA-1 of bencoded info dict); file/piece layout | loader pool |
| `resume` | import transmission `.resume`; write *our* format | loader/disk pool |
| `config` | read transmission `settings.json`; own runtime config | startup |
| `session` | registry (by id + infohash), command queue, tick loop | **session thread** |
| `loader` | dir scan + per-torrent load jobs | loader pool |
| `net` | reactor over io_uring/epoll, socket helpers | reactor thread |
| `tracker` | HTTP + UDP announce/scrape, compact peer-list parse | reactor + session |
| `peer` | handshake + wire framing (reactor) + peer state machine (session) | split |
| `picker` | block/piece selection (v1: rarest-first, no endgame) | session thread |
| `storage` | file↔block mapping, read/write, hash-verify, mtimes | disk pool |
| `rpc` | HTTP server (reactor) + JSON + method dispatch (session) | split |
| `log` | structured records, bound-context loggers, async writer | producers → logger thread |

**Dependency direction:** `rpc`/`tracker`/`peer` → `session` → `torrent`/`picker`/`storage`;
everything may use `bencode` + `log`; nothing depends on `rpc`. Leaf modules (`bencode`,
`metainfo`, `log`) have no engine dependencies and are unit-testable in isolation.

## 5. Data flows

### 5.1 Startup streaming load (the pain-point fix)

1. `main`: parse args → load `settings.json` → init logger → start session thread → start
   reactor **with the RPC listener already accepting connections**.
2. Session thread enumerates `torrents/*.torrent`, submits one load job per file to the loader
   pool, and **returns immediately — no barrier**.
3. Each job, in parallel: read `.torrent`, parse metainfo + infohash, read matching `.resume`,
   import progress/bitfield/priorities/peers/dates → post `TorrentLoaded`.
4. Session thread, per arriving message: assign id, insert into registry, schedule first
   announce, queue a background verify on the disk pool *only if* resume marks it dirty. The
   torrent now appears in `torrent-get`. Emits `torrent.loaded` with context fields.
5. A malformed `.torrent` logs `torrent.load_failed` and is skipped — it never blocks the
   others, unlike a shared `future.get()` barrier.

### 5.2 Download

announce → peer addrs → reactor dials TCP → handshake → bitfield exchange → picker selects
blocks → `request` → `piece` payload → disk pool writes + SHA-1 verifies the completed piece →
session marks piece complete, broadcasts `have`, periodically persists progress → torrent
completes → re-announce `completed`.

## 6. Logging format

- Record: `{ ts, level, subsystem, msg, fields[] }`. `Field` = key + typed value
  (int / str / bool / infohash / peer-addr / piece-idx).
- **Bound-context loggers:** `log.with(.{ .torrent = id, .subsys = .loader })` returns a child
  that auto-attaches those fields to every line. Filter with `grep '"torrent":7'` or by subsystem.
- Subsystems: `loader`, `scanner`, `session`, `tracker`, `peer`, `picker`, `storage`, `rpc`, `net`.
- Two sink formats, auto-selected by `isatty` (overridable by flag/env): **ndjson** (one JSON
  object per line, for tooling) and **pretty** (aligned, colored, for a terminal).
- Global level for v1 (per-subsystem levels deferred). Producers serialize the record into the
  bounded ring and return; the logger thread formats and writes; dropped-on-full counted/reported.

## 7. State compatibility (read-compat, own write)

- **Read:** `settings.json` (download-dir, incomplete-dir, rpc-port/bind/whitelist/auth,
  peer-port, speed limits), `torrents/*.torrent` (standard, left untouched), `resume/*.resume`
  (bencode → imported).
- **Write:** our own state under a **new `conveyance/` subdir** in the config dir. We do **not**
  overwrite transmission's `resume/`, so switching back to the C++ daemon finds its last (stale)
  state rather than corrupted data. Our resume format: a JSON sidecar per infohash with our
  richer fields plus the piece bitfield (base64). `.torrent` files are reused in place.

## 8. RPC surface (v1)

JSON-RPC over HTTP, CSRF-guarded by `X-Transmission-Session-Id` (return 409 + header when
missing/invalid, matching Transmission). Methods: `session-get`, `session-set` (subset),
`session-stats`, `torrent-get`, `torrent-add`, `torrent-start`, `torrent-stop`,
`torrent-remove`, `torrent-verify`, `torrent-set` (subset), `free-space`. Report a matching
`rpc-version`/`rpc-version-minimum` so existing clients negotiate successfully.

## 9. Errors & resource discipline

- Zig error unions throughout; no panics in steady state.
- Per-torrent load failures isolated and logged; never abort startup.
- Tracker errors → exponential backoff + retry; peer protocol violations → drop peer.
- Arena allocator per load-job and per RPC request; long-lived state in a general-purpose allocator.
- Graceful shutdown: persist resume state, drain the logger queue, close sockets.

## 10. Testing strategy (TDD)

- Unit tests for `bencode` / `metainfo` / `resume` against fixtures (reuse real `.torrent` files
  from `transmission/tests/`).
- Golden RPC request/response tests, diffable against a real `transmission-daemon`.
- Concurrency test: torrents appear in the registry individually as scanned, and one malformed
  `.torrent` does not block the others.
- Integration test: download a small torrent end-to-end against a local seed + local tracker.
- Zig's built-in test runner via `zig build test`.

## 11. Decomposition / roadmap

1. **Engine + minimal end-to-end download** — *this spec*.
2. Peer-layer hardening: PEX, encryption (MSE/PE), µTP, fast-extension, webseeds.
3. Magnet metadata fetch, blocklists, port mapping (UPnP/NAT-PMP).
4. Full RPC method coverage + bandwidth scheduling / queueing parity.
5. DHT/LPD; then cross-platform (Windows/macOS) and an optional C-ABI `libtransmission` shim.

## 12. Project layout & build

```
conveyance/
  build.zig  build.zig.zon
  src/{main, log, bencode, metainfo, resume, config,
       session, loader, net, tracker, peer, picker, storage, rpc}/
  tests/fixtures/
  docs/superpowers/specs/
```

Pure Zig + std where possible: SHA-1 → `std.crypto`, JSON → `std.json`, io_uring →
`std.os.linux.IoUring`; a hand-rolled minimal HTTP parser for RPC (requests are simple POSTs).

**Setup prerequisite:** install Zig (~0.14/0.15 stable) — not currently present on the machine.

Build targets: `zig build`, `zig build test`, `zig build run -- --config-dir <dir>`.

## 13. Milestones

- **M0** skeleton + build + logging + `bencode` + `metainfo` + `resume` parse (unit-tested).
- **M1** session thread + loader pool + RPC (`session-get`, `torrent-get`, `torrent-add`) →
  clients connect and watch the streaming load (the pain-point demo).
- **M2** tracker announce (HTTP + UDP) → peers discovered.
- **M3** peer protocol + picker + storage → actual single-torrent download.
- **M4** persistence (our resume write) + `torrent-start/stop/remove/verify` + graceful shutdown.
