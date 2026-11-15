# gitspace (M1)

A workspace-centric git checkout manager. This repository currently implements the **read-only
inventory**: configure gitspace, register mirrors, discover and link existing checkouts, see
what needs attention, and rebuild the index from git and markers. Creation (`co`,
`workspace new`) is M2.

Product scope, CLI contract and acceptance plan live in the planning repository:

```
/data/mjansen/nextcloud/shared/Dokumente/planning/
├── use-cases/12-v1-scope.md
├── use-cases/13-v1-cli.md
├── use-cases/14-v1-acceptance.md
├── implementation/01-v1-plan.md
└── implementation/04-m1-report.md
```

## What works

| Area | Commands |
|---|---|
| Setup, config and health | `setup`, `config [list|get|set]`, `doctor`, `doctor --fix`, `doctor --reindex` |
| Mirrors | `repo add`, `repo ls`, `repo fetch`, `repo rm` |
| Discovery | `scan` (read-only), `link`, `unlink` |
| Inventory | `gitspace`, `ls`, `status`, `show`, `path` |
| Recovery | `reindex` — rediscover mirrors from disk, rebuild workspaces from markers |
| Machine surface | `--json` on every command, exit codes 0–7, `--verbose` prints git argv |

76 checks (72 tests, 3 properties, 1 doctest) in ~4 s.

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

First run:

```sh
gitspace setup --data ~/.local/share/gitspace --checkouts /data/work
gitspace config
gitspace repo add git@github.com:org/repo.git
gitspace repo ls
gitspace scan ~/src
gitspace link ~/src/old-api
gitspace
gitspace ls --repo repo
gitspace status <workspace>
gitspace doctor
```

Configuration is TOML at `$XDG_CONFIG_HOME/gitspace/config.toml` (or `GITSPACE_CONFIG`).
`GITSPACE_DATA` and `GITSPACE_CHECKOUTS` override the paths. The index is
`<data>/index.sqlite3`; mirrors live under `<data>/repos/`.

`gitspace config` shows the effective values and whether each comes from the file, the
environment or a default. `config set` rewrites the file only; an environment override still
wins at runtime and is reported after the write.

## Decisions

- **Subprocess:** `Exile` (`stderr: :consume`) because it keeps stdout and stderr separate.
  `MuonTrap` cannot capture both simultaneously.
- **Environment:** `env -u …` per invocation, not mutating the VM environment. Exile inherits
  the parent env and cannot unset; `env -u` is the per-call boundary.
- **Mirror refspec:** `+refs/heads/*:refs/remotes/origin/*`. `git clone --bare` writes no
  refspec on git 2.56.
- **Untracked archive:** system `tar` for Linux v1. `:erl_tar.create/3` does not honour
  `{:cwd, …}` for creation.
- **Config:** TOML via `toml_elixir ~> 3.3`.
- **Index:** `ecto_sqlite3` + `exqlite`, pool size 1, WAL, migrations on demand.
- **Recovery:** the SQLite index is disposable; mirrors are rediscovered from
  `<data>/repos/*.git`, workspaces from `<root>/<work>/.gitspace.json` markers.
- **Status cache:** 1 h TTL. `ls` and the inbox read the cache; `status --refresh` computes.
  The first view refreshes up to 20 checkouts that have never been measured.
- **Git floor:** 2.40.
- **Packaging:** `mix release` + Burrito 1.5.0 with the host glibc ERTS.

## Burrito caveats — do not “fix” these casually

1. **Keep `skip_nifs: true`.** Burrito treats every Linux target as a cross-build and
   recompiles NIF deps with `zig cc … -shared`. Exile's `spawner` is an executable and is
   corrupted by `-shared` (entry point `0x0`, segfault on every spawn).
2. **Use the exact running ERTS, not the OTP root.** The host has several `erts-*` versions;
   Burrito picks the first. The target sets:

   ```elixir
   custom_erts:
     System.get_env("GITSPACE_ERTS") ||
       Path.join(to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}")
   ```

   This bundles glibc ERTS so `exqlite`'s NIF loads. Burrito's musl ERTS fails with
   `__memmove_chk: symbol not found`. The binary is native-Linux portable, not Alpine/musl
   portable.

Binary: **7.0 MB**, cold start 1.58 s (payload extraction), warm `ls` 0.60 s, warm `doctor`
1.37 s.

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

`status` is ~240 ms per checkout on that repository, which is why the cache is mandatory.

## Known limits

- Creation is not implemented yet; M1 indexes worktrees created by `git` or by `reindex`.
- External checkouts are index-only: `unlink` forgets them and a later reindex cannot
  rediscover them unless you `scan`/`link` again.
- Submodules are checked out as empty directories; LFS pointer files are checked out verbatim.
- `scan` does not follow symlinks.
- Stable checkout IDs survive normal reruns and reindexes, but not deletion of the index;
  workspace identity is recovered from markers.
- `doctor --fix` prunes worktree metadata; use `--reindex` to reconcile missing checkout rows.
- The interactive prompts are covered by manual use; the non-TTY contract is tested.

## Not here yet

M2 creation (`co`, `workspace new`, branch derivation, markers, occupied-branch dialog),
M3 teardown/prune/safety, M4 handoff and `run --all`, M5 full machine contract and performance,
M6 dogfood and release.
