# gitspace (M2)

A workspace-centric git checkout manager. This repository now implements the **creation and
inventory path**: configure gitspace, register mirrors, create one-repo checkouts and
multi-repo workspaces, discover and link existing checkouts, see what needs attention, and
rebuild the index from git and markers. Teardown and pruning are M3.

Product scope, CLI contract and acceptance plan live in the planning repository:

```
/data/mjansen/nextcloud/shared/Dokumente/planning/
├── use-cases/12-v1-scope.md
├── use-cases/13-v1-cli.md
├── use-cases/14-v1-acceptance.md
├── implementation/01-v1-plan.md
├── implementation/04-m1-report.md
└── implementation/05-m2-report.md
```

## What works

| Area | Commands |
|---|---|
| Creation | `co`, `workspace new`, `workspace ls`, `workspace status` |
| Setup, config and health | `setup`, `config [list|get|set]`, `doctor`, `doctor --fix`, `doctor --reindex` |
| Mirrors | `repo add`, `repo ls`, `repo fetch`, `repo alias`, `repo rm` |
| Discovery | `scan` (read-only), `link`, `unlink` |
| Inventory | `gitspace`, `ls`, `status`, `show`, `path` |
| Recovery | `reindex` — rediscover mirrors from disk, rebuild workspaces from markers |
| Machine surface | `--json` on every command, exit codes 0–7, `--verbose` prints git argv |

138 checks (134 tests, 3 properties, 1 doctest) in ~21 s.

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
gitspace co api@hotfix/timeout
gitspace workspace new JENKINS-123 --own api --own web --borrow shared-lib@main
gitspace workspace status JENKINS-123
gitspace scan ~/src
gitspace link ~/src/old-api
gitspace
gitspace ls --repo repo
gitspace status <workspace>
gitspace doctor
```

Configuration is TOML at `$XDG_CONFIG_HOME/gitspace/config.toml` (or `GITSPACE_CONFIG`).
`GITSPACE_DATA` and `GITSPACE_CHECKOUTS` override the paths. The index is
`<data>/index.sqlite3`; mirrors live under `<data>/repos/<sha256>.git`, with the readable
`<data>/repos/remotes.txt` index beside them.

`gitspace config` shows the effective values and whether each comes from the file, the
environment or a default. `config set` rewrites the file only; an environment override still
wins at runtime and is reported after the write.

## Creation model

- `co <repo>@<ref>` creates a one-repo workspace. The default work name is the sanitized ref
  (`hotfix/timeout` → `hotfix-timeout`); the path is `<checkouts>/<work>/<repo>`.
- A branch ref checks out that branch (creating the local branch from `origin` when needed).
  A tag or commit is detached. `--branch` creates a named branch from the ref; `--detach`
  forces detached.
- `workspace new <name> --own <repo>` derives `feature_<work>` from the repository's default
  branch. `--branch` overrides; an explicit `repo@ref` opts out and checks out that ref as-is.
- `--borrow <repo>[@<ref>]` references an existing checkout. It is never moved, branched or
  deleted. With several checkouts, `@<ref>` selects one by branch or commit.
- Creation is ensure-only: matching members are reused, conflicting paths or branches are
  errors, and nothing is overwritten. Re-running a subset leaves existing members untouched.
- An occupied branch prompts for borrow / new branch / detach / cancel on a terminal. With
  `--json` or no terminal it is a `branch_occupied` error (exit 4).
- Worktrees are created first; the marker is written only for successful members. A missing
  ref or failed member yields exit 7, and re-running the same command completes the workspace.
- `--fetch` is opt-in and only runs when a requested ref is missing. Warm mirrors work offline.

## Repository aliases, mirrors and collisions

A repository's alias is its short name in commands and its default member directory. Auto
aliases use the basename: `.../ferroclass.git` becomes `ferroclass`. When different remotes
share a basename, every auto-aliased member of that group is qualified with its group:
`github.com/acme/config` and `github.com/beta/config` both become `acme-config` and
`beta-config`. If groups still collide across hosts, the host is prefixed
(`github.com-acme-config`); a content hash is the final fallback. Aliases stay globally unique.

Mirrors are content-addressed by canonical remote key: `<data>/repos/<sha256>.git`.
`<data>/repos/remotes.txt` is a human-readable cache of `hash`, canonical remote, alias and
alias source. Mirror directories and their `remote.origin.url` are authoritative; `doctor` and
`reindex` report disagreements and rebuild the text index.

An explicit name opts a repository out of auto-disambiguation. The bare basename is allowed if
it is free; duplicate explicit aliases are errors.

```sh
gitspace repo add git@github.com:acme/config.git   # auto: acme-config if config collides
gitspace repo add git@github.com:beta/config.git --name config
gitspace repo add git@gitlab.com:beta/config.git --name beta-config
gitspace repo alias acme-config my-config         # permanent alias change
```

`repo add` also accepts an existing clone or worktree instead of a URL:

```sh
gitspace repo add ~/src/ferroclass              # uses its only remote
gitspace repo add ~/src/app --remote upstream   # picks one remote explicitly
```

With one remote, its URL is registered automatically. With several, `repo add` refuses and
lists the candidates until you choose one with `--remote <name>`. A local git repository with
no remotes is still mirrored from its path, as before.

Aliases may change when repositories are added; checkout directories never move. Member
directories are chosen per checkout and recorded in the workspace marker:

```sh
gitspace co api@main --as api-main
gitspace workspace new JENKINS-123 --own api --as api=v2-api --own web
```

All checkouts remain top-level under `<checkouts>/<workspace>/`; there are no per-repository or
group subdirectories. Existing member names are immutable: asking for a different `--as` name
for an existing member is a conflict.

The same remote written in another URL form (`git@…`, `https://…`, with or without `.git`) is
matched by its canonical remote key and is not duplicated. Default ports are omitted; other
ports remain part of the key. `gitspace repo ls` shows the remote, alias, and mirror hash behind
each repository.

## Listing

`gitspace ls` is compact by default: repository alias, workspace, branch, dirty/ahead/behind/
unpushed counts, and age. It intentionally omits paths and mirror details so a normal table
fits in roughly 100 characters.

```sh
gitspace ls
gitspace ls --verbose      # adds HASH and MIRROR
gitspace ls --wide         # old name for --verbose
gitspace ls --json         # full rows, including path and mirror metadata
```

Use `gitspace path <target>` or `gitspace show <target>` when the checkout path is what you
need.

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
  `<data>/repos/*.git`, `remotes.txt` is rebuilt from the mirrors, and workspaces from
  `<root>/<work>/.gitspace.json` markers.
- **Checkout paths:** the workspace marker is authoritative. Alias changes never move an
  existing checkout; member names are chosen at creation and stay immutable.
- **Status cache:** 1 h TTL. `ls` and the inbox read the cache; `status --refresh` computes.
  The first view refreshes up to 20 checkouts that have never been measured.
- **Creation:** ensure-only and marker-first for recovery. Worktrees are created before the
  marker is written; a partial run leaves only successful members, so a re-run completes it.
- **Refs:** local branch → remote branch → tag → commit. Branch identity is per mirror, so
  `main` in one repository never blocks `main` in another.
- **TTY detection:** read the stdin device (`/proc/self/fd/0`). `:io.columns()` returns
  `:enotsup` in release-style stdin even under a PTY. `GITSPACE_NO_PROMPT=1` forces off.
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
3. **Burrito caches the extracted payload by app version.** Replacing the binary while
   keeping `version: "0.1.0"` keeps running the old extracted payload under
   `$XDG_DATA_HOME/.burrito/gitspace_erts-*_<version>`. Bump `version` in `mix.exs` for each
   packaged build, or remove that directory after replacing the binary.

Binary: **7.1 MB**, cold start 1.58 s (payload extraction), warm `ls` 0.60 s, warm `co` 0.64 s,
warm `doctor` 1.37 s.

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

- Teardown, `prune` and the full safety net are M3.
- External checkouts are index-only: `unlink` forgets them and a later reindex cannot
  rediscover them unless you `scan`/`link` again.
- Submodules are checked out as empty directories; LFS pointer files are checked out verbatim.
- `scan` does not follow symlinks.
- Stable checkout IDs survive normal reruns and reindexes, but not deletion of the index;
  workspace identity is recovered from markers.
- `doctor --fix` prunes worktree metadata; use `--reindex` to reconcile missing checkout rows.
- The occupied-branch dialog has unit and strategy coverage plus a PTY smoke test; a fully
  automated PTY suite is not in place. The non-TTY and `--json` contracts are tested.
- `GITSPACE_NO_PROMPT=1` forces non-interactive behaviour even when stdin is a terminal.
- `workspace ls` lists active workspaces; `--all`/torn-down listings belong with M3 teardown.
- `--dry-run` does not fetch, even with `--fetch`; it reports what the current mirror can do.
- A partial run with **no** successful member returns the original error and writes no marker.
- Borrowing a checkout that is owned by another workspace is allowed; M3 teardown must
  reconcile that reference instead of deleting it.

## Not here yet

M3 teardown/prune/safety, M4 handoff and `run --all`, M5 full machine contract and performance,
M6 dogfood and release.
