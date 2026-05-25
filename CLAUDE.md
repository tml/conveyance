# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

Zig **0.14.x**, installed at `~/.local/bin/zig` (add to PATH if missing).

```bash
export PATH="$HOME/.local/bin:$PATH"
zig build                                # compile the daemon
zig build test                           # run all unit tests (src/root.zig aggregates them)
zig build run -- --config-dir <dir>      # run the daemon
```

## Architecture Overview

Conveyance is a Zig reimplementation of Transmission's core engine, packaged as a **drop-in
`transmission-daemon`** speaking the same JSON-RPC/HTTP protocol. Hybrid runtime: a single
**session-owner thread** mutates all torrent/peer state; a **net reactor** (io_uring/epoll)
handles all sockets; a **loader thread-pool** streams torrents into an interactive state *as each
is scanned* (the core pain-point fix); a dedicated thread drains structured logs.

- Design spec: `docs/superpowers/specs/2026-05-24-conveyance-zig-transmission-backend-design.md`
- Implementation plans: `docs/superpowers/plans/`
- Milestones M0–M4 are beads epics; granular tasks live under them (e.g. `conveyance-09m.1`).

## Conventions & Patterns

### Task tracking — beads
Create/claim a bead **before** writing code; close it when `zig build test` is green. (See the
Beads Issue Tracker section above for commands.)

### Persisting work — TOON
When asked to **persist work** (status snapshots, structured data dumps, hand-off state), use
**TOON** (Token-Oriented Object Notation), not JSON/YAML. Spec: https://github.com/toon-format/toon
Indentation denotes nesting (`key: value`); uniform object arrays use tabular rows
(`arr[N]{f1,f2}:` then comma-separated rows); scalar arrays use `arr[N]: a,b,c`.

### Doc generation — 3 passes
Whenever generating docs, produce: (1) a **markdown** pass, then (2) **two HTML** passes — one
**business-facing**, one **deeply technical**. Use **mermaid** diagrams for visuals and include
**mermaid.ink** image links so the diagrams render inline in the HTML.

### Zig style
- Error unions for fallible ops; no panics in steady state.
- Allocator discipline: arena per load-job / per-RPC-request; long-lived state in a
  GeneralPurposeAllocator. Document who owns and frees each allocation.
- One responsibility per file; keep files small and focused.
- TDD: write the failing test first; never change a test's asserted behavior just to make it pass.
- Unit tests must not touch the network; use fixtures under `tests/fixtures/`.

### Subagent rules
Read the relevant plan + this file before starting. Install Zig via the PATH shim if missing. Run
`zig build test` and report the actual output before claiming a task done.
