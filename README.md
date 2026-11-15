# gitspace (M0 spike)

The mechanics spike for a workspace-centric git checkout manager. **Not the product yet** —
this repo proves the git, safety and packaging mechanics that the v1 plan depends on.

The product scope, CLI surface, acceptance plan and implementation plan live in the planning
repository:

```
/data/mjansen/nextcloud/shared/Dokumente/planning/
├── use-cases/12-v1-scope.md
├── use-cases/13-v1-cli.md
├── use-cases/14-v1-acceptance.md
├── implementation/01-v1-plan.md
└── implementation/03-m0-report.md
```

## What is proven

| Area | Status |
|---|---|
| Bare mirror recipe (`refs/remotes/origin/*`, no `--mirror`) | tests pass |
| Worktree add/list/remove, occupied branch, prunable metadata | tests pass |
| Porcelain v2 status parsing | tests pass |
| Upstream / ahead / behind / “exists nowhere else” | tests pass |
| Work-name slug, path containment, branch templates | property tests pass |
| Workspace recovery marker read/write/find | tests pass |
| Safety: keep ref + `gc --prune=now`, stash create, untracked tar, bundle | tests pass |
| Submodule and LFS repositories | no-crash probes pass |
| Standalone Burrito binary | builds and runs |

44 checks (40 tests, 3 properties, 1 doctest) in ~1.2 s.

## Commands

The Makefile wraps the common work; `make help` lists everything.

```sh
make build         # compile with warnings as errors
make test          # test suite
make lint          # format check + warnings-as-errors
make ci            # lint, then tests
make burrito       # standalone binary

make run ARGS=doctor
make bench         # synthetic benchmark
make bench BENCH_REPO=/path/to/repo BENCH_WORKTREES=2 BENCH_DIR=/data/tmp/gitspace-bench

make install       # installs gitspace and the gsp alias under $(PREFIX)/bin
make install DESTDIR=/tmp/stage PREFIX=/usr/local
```

Raw equivalents:

```sh
mix test
mix compile --warnings-as-errors
mix run bench/bench.exs
GITSPACE_BENCH_REPO=/path/to/real/repo GITSPACE_BENCH_WORKTREES=2 mix run bench/bench.exs

BURRITO_TARGET=linux_x86_64 MIX_ENV=prod mix release --overwrite
./burrito_out/gitspace_linux_x86_64 doctor
```

`Makefile.local` is ignored by git and included if present, for local overrides. Do not
export `DESTDIR` or `PREFIX` into the Burrito build: Zig honours them and installs the
wrapper outside `zig-out/bin`, which breaks Burrito's copy step. The Makefile unexports them
for this reason.

## Decisions

- **Subprocess:** `Exile` (`stderr: :consume`) because it keeps stdout and stderr separate.
  `MuonTrap` cannot capture both simultaneously.
- **Environment:** `env -u …` per invocation, not mutating the VM environment. Exile inherits
  the parent env and cannot unset; `env -u` is the per-call boundary.
- **Mirror refspec:** `+refs/heads/*:refs/remotes/origin/*`. `git clone --bare` writes no
  refspec on git 2.56.
- **Untracked archive:** system `tar` for Linux v1. `:erl_tar.create/3` does not honour
  `{:cwd, …}` for creation.
- **Config:** TOML via `toml_elixir ~> 3.3` (TOML 1.0/1.1, maintained, no runtime deps).
- **Packaging:** `mix release` + Burrito 1.5.0 (matches the installed Zig 0.15.2).
- **Git floor:** 2.40.
- **Test isolation:** `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`, fixed
  author/committer dates. This machine sets `tag.gpgSign = true` globally.

## Burrito caveat — do not remove `skip_nifs`

Burrito treats **every** Linux target as a cross-build and rebuilds NIF dependencies with
`zig cc … -shared`. Exile ships an executable helper (`spawner`), and linking it with
`-shared` produces a file with entry point `0x0` and `DT_NEEDED libc.so`. It segfaults on
every spawn, and because `deps/exile/priv` is symlinked into every `_build` env, it breaks
`mix test` too.

The target therefore sets `skip_nifs: true`; the native build uses host-compiled NIFs. If the
`zig cc` path is ever needed, Exile's Makefile must be patched to strip `-shared` from the
`spawner` rule.

## Benchmarks

Synthetic (200 files, overhead only): mirror 33 ms, `co` 6.7 ms, `worktree list` 2.7 ms,
status (20) 61.6 ms.

`rust/opencode` (582 MB `.git`, 8,816 tracked files, local-path remote):

| Operation | Time |
|---|---|
| mirror init + fetch | 18.9 s |
| `co` (first worktree) | 1.0 s |
| `co` (second worktree) | 1.2 s |
| `worktree list` (2) | 4.2 ms |
| `status` (2 checkouts) | 480 ms |

`status` is ~240 ms per checkout, which is why status caching is mandatory in the product.

Binary startup: 1.39 s cold (payload extraction), 0.20 s warm, 16 MB.

## Known limits

- Submodules are checked out as empty directories; they are not initialised.
- LFS pointer files are checked out verbatim; LFS content is not in the mirror.
- The status parser still needs to skip the extra NUL token of rename records (M1).
- `unshare -n` is unavailable here; offline benchmarks use `GIT_ALLOW_PROTOCOL=file`.

## Not here yet

CLI surface, config/setup, SQLite/Ecto, workspace creation/teardown, inbox, reindex, prune.
That is M1+ in `implementation/01-v1-plan.md`.
