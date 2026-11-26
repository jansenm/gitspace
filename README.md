# gitspace (M2)

A workspace-centric git checkout manager. This repository implements the **creation and
inventory path**: configure gitspace, register mirrors, define projects, check out topics,
discover and link existing checkouts, see what needs attention, and rebuild the index from git
and markers. Pruning and the full safety net are M3.

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
| Creation | `project new|ls|show|add|remove|rm`, `co`, `workspace new|ls|status|rm` |
| Setup, config and health | `setup`, `config [list|get|set]`, `doctor`, `doctor --fix`, `doctor --reindex` |
| Completion | `completion bash|zsh|fish` |
| Mirrors | `repo add`, `repo ls`, `repo fetch`, `repo alias`, `repo set-url`, `repo rm` |
| Discovery | `scan` (read-only), `link`, `unlink` |
| Inventory | `gitspace`, `ls`, `status`, `show`, `path` |
| Recovery | `reindex` — rediscover mirrors from disk, rebuild workspaces from markers |
| Machine surface | `--json` on every command, exit codes 0–7, `--verbose` prints git argv |

169 checks (165 tests, 3 properties, 1 doctest) in ~45 s.

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
gitspace setup --data ~/.local/share/gitspace --projects /data/work
gitspace config
gitspace repo add git@github.com:org/repo.git
gitspace repo ls
gitspace project new api --repo api
gitspace co api@main --topic dev
gitspace co api@main --topic JENKINS-123
gitspace project new webapp --repo api --repo web
gitspace co webapp@main --topic JENKINS-123 --only api,web
gitspace workspace status webapp@JENKINS-123
gitspace scan ~/src
gitspace link ~/src/old-api
gitspace
gitspace ls --repo repo
gitspace status <workspace>
gitspace doctor
gitspace completion bash
```

Configuration is TOML at `$XDG_CONFIG_HOME/gitspace/config.toml` (or `GITSPACE_CONFIG`).
`GITSPACE_DATA` and `GITSPACE_PROJECTS_ROOT` override the paths. The index is
`<data>/index.sqlite3`; mirrors live under `<data>/repos/<sha256>.git`, with the readable
`<data>/repos/remotes.txt` index beside them.

`gitspace config` shows the effective values and whether each comes from the file, the
environment or a default. `config set` rewrites the file only; an environment override still
wins at runtime and is reported after the write.

## Projects, topics and workspaces

A **project** is a named set of registered repositories. A **topic** is the piece of work.
Their combination is a **workspace**, and every checkout has exactly one shape:

```text
<projects.root>/<project>/<topic>/<member>
```

```text
/data/work/ferroclass/dev/ferroclass
/data/work/ferroclass/release-2.4/ferroclass
/data/work/vemags/MT4711/api
/data/work/vemags/MT4711/web
```

There is no one-repo path special case: a one-repo project is the normal case, and it can grow
later without moving existing checkouts.

```sh
gitspace project new vemags --repo api --repo web --description "VEMAGS services"
gitspace project add vemags legacy
gitspace project show vemags
gitspace project ls
gitspace project remove vemags legacy
```

By default a project lives at `projects.root/<name>`. `--at` names the project directory
itself, used verbatim and required to end with the project name:

```sh
gitspace project new acme-java --at /mnt/customer/acme-java
```

Projects are user intent and live in `<data>/projects.toml`. A project can contain one repo or
many; a repository may belong to more than one project. `repo add --project P` registers and
links in one step.

### `co` and branch modes

`co` always targets a project. If no project exists but a registered repository has that name,
a one-repo project is created implicitly. Naming a repository never expands to a project that
contains it; name the project to check out its other members.

```sh
gitspace co ferroclass@main --topic dev
gitspace co ferroclass@release/2.4
gitspace co vemags@development --topic MT4711
gitspace co vemags@feature/MT4711 --topic MT4711
gitspace co vemags@development --topic MT4711 --only api,web
gitspace co vemags@feature/MT4711 --topic MT4711 --exclude legacy
```

`@<ref>` is the starting point. Naming a topic means creating work:

| Flags | Result |
|---|---|
| no `--topic`/`--name` | check out the ref as-is (branch, or detached for tag/SHA) |
| `--topic T` / `--name T` | derive an owned branch from `feature/{topic}`, starting at the ref |
| `--branch B` | create the explicit owned branch `B` from the ref |
| `--as-is` | check out the ref unchanged even with a topic |
| `--detach` | detached checkout at the ref |

Re-running the same command resumes an existing owned branch when it is free. An occupied
branch asks for borrow / new branch / detach / cancel on a terminal; with `--json` or no
terminal it is a `branch_occupied` error (exit 4). `--branch`, `--as-is` and `--detach` are
mutually exclusive.

`--only M,...` and `--exclude M,...` select the project members for this invocation, and are
mutually exclusive. The default is every member. **A repository that already has a checkout in
the topic workspace is ignored**, even when the requested ref or branch mode differs. Re-running
after adding a project member therefore adds only the missing member; no `--only` is needed.
Exclusions never delete existing members.

`workspace new` remains the explicit form:

```sh
gitspace workspace new vemags@4711 --own api@main --own web@main
gitspace workspace new 4711/sub --own api@main      # topic 4711/sub, project inferred
```

The target is `[<project>@]<topic>`. `@` separates project and topic; topics may contain `/`,
but `@` is reserved in project names, topics and repository aliases. Without a project the
first owned repository's project is used. Owned branches are derived from the topic using the
project template (default `feature/{topic}`); `--branch` overrides the name and `--as-is`
checks the ref out unchanged. Labels, descriptions, `--as repo=name`, `--fetch` and `--dry-run`
work as before.

Creation is ensure-only: matching members are reused, conflicting paths or branches are
errors, and nothing is overwritten. Worktrees are created first; the marker is written after
successful members. A missing ref or failed member yields exit 7, and re-running the same
command completes the workspace. `--fetch` is opt-in and only runs when a requested ref is
missing. Warm mirrors work offline.

The marker lives at `<project.path>/<topic>/.gitspace.json`, outside every member checkout.

## Repository aliases, mirrors and collisions

A repository's alias is its short name in commands and its default member directory. Auto
aliases use the basename: `.../ferroclass.git` becomes `ferroclass`. When different remotes
share a basename, every auto-aliased member of that group is qualified with its group:
`github.com/acme/config` and `github.com/beta/config` both become `acme-config` and
`beta-config`. If groups still collide across hosts, the host is prefixed
(`github.com-acme-config`); a content hash is the final fallback. Aliases stay globally unique.

Mirrors are named by the repository's **immutable identity**: `<data>/repos/<sha256>.git`.
The identity is assigned once when the repository is registered and written into the mirror as
`gitspace.remote-key`; `remote.origin.url` is only the fallback for mirrors created before that
key was pinned. `<data>/repos/remotes.txt` is a human-readable cache of `hash`, identity, alias
and alias source. `doctor` and `reindex` report disagreements and rebuild the text index.

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
lists the candidates until you choose one with `--remote <name>`. A path without a remote is
refused rather than implicitly mirrored; pass a remote URL instead.

When fetching is enabled, the mirror is seeded from the checkout with
`git clone --reference <checkout> --dissociate`, so objects already present locally are reused
and the new mirror is then disconnected from the checkout. `--no-fetch` stays fully offline
and does not use the reference clone.

Aliases may change when repositories are added; checkout directories never move. Member
directories are chosen per checkout and recorded in the workspace marker:

```sh
gitspace co api@main --as api-main
gitspace workspace new vemags@JENKINS-123 --own api --as api=v2-api --own web
```

All owned checkouts remain direct children of the topic workspace:
`<project.path>/<topic>/<member>`. Existing member names are immutable: asking for a different
`--as` name for an existing member is a conflict.

The same remote written in another URL form (`git@…`, `https://…`, with or without `.git`) is
matched by its canonical address and is not duplicated, even after its fetch URL was changed.
Default ports are omitted; other ports remain part of the address. `gitspace repo ls` shows the
remote, alias, and mirror hash behind each repository.

## Changing remote URLs

`repo set-url` changes the mirror's fetch URL. `--push` changes the push URL instead:

```sh
gitspace repo set-url ferroclass git@github.com:jansenm/ferroclass.git
gitspace repo set-url ferroclass git@gitlab.com:jansenm/ferroclass.git
gitspace repo set-url ferroclass git@github.com:jansenm/ferroclass.git --push
```

A repository's identity is immutable, so any host, port or path may change: the mirror
directory, index rows, project members and markers all keep referring to the same repository.
Only an address that already belongs to another repository is refused. A remote with several
fetch or push URLs is also refused instead of guessing which one to replace.

## Removing workspaces

```sh
gitspace workspace rm vemags@MT4711          # every member, then the workspace
gitspace workspace rm vemags@MT4711:api      # one member
gitspace workspace rm vemags@MT4711 --dry-run
```

- Owned members are removed as git worktrees; borrowed members are unlinked and their
  checkouts stay in place.
- Removing the last member tombstones the workspace. The project directory and definition
  remain.
- Risky owned members (dirty, untracked, or unpushed work) are refused. `--force` anchors
  HEAD and saves the tracked diff plus untracked files under `<data>/trash` before removal.
- Branches are never deleted. Branches of removed owned members are reported as
  `branches kept`, in `--dry-run` and after removal, so nothing disappears silently.
- `--yes` is required without a terminal; `--dry-run` shows the plan without changing anything.

## Shell completion

```sh
# bash
source <(gitspace completion bash)

# zsh
gitspace completion zsh > "${fpath[1]}/_gitspace"

# fish
gitspace completion fish | source
```

Completions cover commands, subcommands, flags, project names, repository aliases,
workspace handles, bare topics, project members and config keys. They call the hidden
`gitspace __complete` command, so they follow the live index rather than a static snapshot.

## Listing

`gitspace ls` is compact by default: project, topic, member, branch, dirty/ahead/behind/
unpushed counts, and age. It intentionally omits paths and mirror details so a normal table
fits in roughly 100 characters.

```sh
gitspace ls
gitspace ls --verbose      # adds HASH and MIRROR
gitspace ls --wide         # old name for --verbose
gitspace ls --project P    # one project
gitspace ls --topic T      # one topic across projects
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
  `<data>/repos/*.git`, `remotes.txt` is rebuilt from the mirrors, projects from
  `<data>/projects.toml`, and workspaces from `<project>/<topic>/.gitspace.json` markers
  (workspace names are `project@topic`).
- **Checkout paths:** the workspace marker is authoritative. Project paths and topic names are
  chosen at creation and never re-derived; alias changes never move an existing checkout.
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

- `prune` and the full safety net are M3; `workspace rm` covers safe workspace and member
  removal.
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
- Borrowing a checkout that is owned by another workspace is allowed; `workspace rm` refuses
  to remove a checkout that is still referenced by another active workspace.

## Not here yet

M3 prune/safety and torn-down listings, M4 handoff and `run --all`, M5 full machine contract
and performance, M6 dogfood and release.

## License

Mozilla Public License 2.0. See [LICENSE](LICENSE) and [REUSE.toml](REUSE.toml).
