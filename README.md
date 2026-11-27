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
| Creation | `checkout` (`co`), `workspace new|add`, `project new|env|secret|add|remove`, `repo init|import|add` |
| Setup, config and health | `setup`, `config list|get|set|export|import`, `doctor check|fix|reindex|keep` |
| Completion | `completion bash|zsh|fish` |
| Mirrors | `repo init`, `repo import`, `repo add`, `repo ls`, `repo branches`, `repo fetch <repo>|--all`, `repo alias`, `repo set-url`, `repo rm` |
| Discovery | `scan` (read-only), `link`, `unlink` |
| Inventory | `gitspace`, `ls`, `show`, `status`, `path`, `env`, `shell`, `log` |
| Publishing | `push`, `rebase`, `base` |
| Maintenance | `doctor keep ls|prune` |
| Recovery | `doctor reindex` — rediscover mirrors from disk, rebuild workspaces from markers |
| Machine surface | `--json` on every command, exit codes 0–7, `--verbose` prints git argv |

335 checks (331 tests, 3 properties, 1 doctest) in ~65 s.

## Commands

The Makefile wraps the common work; `make help` lists everything.

```sh
make build         # compile with warnings as errors
make test          # test suite
make lint          # format check + warnings-as-errors
make ci            # lint, then tests
make burrito       # standalone binary
make man           # lint and render man/gitspace.1

make run ARGS=doctor
make bench         # synthetic benchmark
make bench BENCH_REPO=/path/to/repo BENCH_WORKTREES=2 BENCH_DIR=/data/tmp/gitspace-bench

make install       # binary, gsp alias and manpage under $(PREFIX)
make install-man   # manpage only
make install DESTDIR=/tmp/stage PREFIX=/usr/local
```

The full reference is in `man/gitspace.1`; `make install` installs it as `gitspace(1)` under
`$(MANPREFIX)/man1`.

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
gitspace status webapp@JENKINS-123
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

`gitspace config export [--output FILE]` writes a versioned JSON bundle of **projects and
remote-backed repositories**. Workspaces, checkouts, labels, absolute paths and credentials are
not included; local repositories are skipped. `gitspace config import <FILE|->` only creates
missing repositories and projects. Existing entries are left untouched. A project whose member
was skipped is created without that member and the import is reported as partial. Import is
idempotent and needs `--yes` without a terminal; `--dry-run` and `--no-fetch` are available.

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
gitspace show project:vemags
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

`@<ref>` is the starting point:

| Flags | Result |
|---|---|
| no `--topic`/`--name` | check out the ref as-is (branch, or detached for tag/SHA) |
| `--topic T` with a ref | derive an owned branch from `feature/{topic}`, starting at the ref |
| `--topic T` without a ref | derive an owned branch from `feature/{topic}`, starting at **each repository's default ref** (`main`, `master`, `devel`, …) |
| `--branch B` | create the explicit owned branch `B` from the ref or default |
| `--as-is` | check out the ref (or default) unchanged even with a topic |
| `--detach` | detached checkout at the ref |

Re-running the same command resumes an existing owned branch when it is free. An occupied
branch asks for borrow / new branch / detach / cancel on a terminal; with `--json` or no
terminal it is a `branch_occupied` error (exit 4). `--branch`, `--as-is` and `--detach` are
mutually exclusive.

The topic is inserted into the branch template **verbatim**, including `/`: topic
`jenkins/ejb-remoting` with the default template gives `feature/jenkins/ejb-remoting`, matching the
remote ref. Only the workspace directory is slugged (`jenkins-ejb-remoting`). `--branch` uses the
given name verbatim, and `--as-is` checks out the ref unchanged.

`--only M,...` and `--exclude M,...` select the project members for this invocation, and are
mutually exclusive. The default is every member. **A repository that already has a checkout in
the topic workspace is ignored**, even when the requested ref or branch mode differs. Re-running
after adding a project member therefore adds only the missing member; no `--only` is needed.
Exclusions never delete existing members.

`workspace new` creates a workspace; `workspace add` extends an existing one and fails if the
workspace does not exist, so a typo cannot silently create a second workspace:

```sh
gitspace workspace new vemags@4711 --own api@main --own web@main
gitspace workspace new 4711/sub --own api@main      # topic 4711/sub, project inferred
gitspace workspace new vemags@dev --own api --own web --as-is  # each default branch
gitspace workspace add vemags@4711 --own api@main               # add a member
```

The target is `[<project>@]<topic>`. `@` separates project and topic; topics may contain `/`,
but `@` is reserved in project names, topics and repository aliases. Without a project the
first owned repository's project is used. Owned branches are derived from the topic using the
project template (default `feature/{topic}`); the topic is used verbatim, including `/`, while
only the workspace directory is slugged. `--branch` overrides the name and `--as-is` checks the
ref (or each repository's default branch) out unchanged. Labels, descriptions, `--as repo=name`, `--fetch` and `--dry-run`
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
refused rather than implicitly mirrored; use `gitspace repo import <path>` or pass a remote URL.

### Local repositories

A repository can live in gitspace without any upstream. The mirror is the source of truth and
its worktrees share the object store:

```sh
gitspace repo init demo                        # empty repo, first checkout on main
gitspace repo init demo --branch devel --topic dev
gitspace repo import ~/src/scratch --name scratch   # copy history from a local clone
gitspace repo import ~/src/scratch --no-link        # do not index the source clone
```

`repo init` creates the mirror, an implicit one-repo project and the first checkout; commit in
that checkout and the branch exists immediately, with no push or fetch. `repo import` copies
committed history into a local mirror offline, leaves the source clone untouched, and links it
as an external checkout unless `--no-link`. Both use an identity of `local:<uuid>`; `repo ls`
shows them as `LOCAL`. A local repository keeps the name chosen at import (`--name`, otherwise
the source directory's basename) across reindexing. `repo fetch` is a no-op, and `repo rm`
writes `git bundle --all` under `<data>/trash/repos/` before deleting the mirror, because that
mirror is the only copy.
`repo set-url <repo> <url>` adopts an upstream later without changing the identity.

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
Default ports are omitted; other ports remain part of the address. `gitspace repo ls` is compact
by default and shows the remote behind each repository; `--verbose` adds the mirror hash and
path.

## Browsing branches

`repo branches` shows what a repository can check out before you create a workspace. It lists
local branches, remote branches (plain names, so `co repo@feature/x` works) and, with `--tags`,
tags. The default branch and every branch already checked out in a worktree are marked.

```sh
gitspace repo branches vemags
gitspace repo branches vemags --match 'feature/*'   # glob: * and ?
gitspace repo branches vemags --regex '^JENKINS-'
gitspace repo branches vemags --tags
```

`--match` and `--regex` are mutually exclusive and filter by branch name. Filters apply to
local and remote branches as well as tags.

## Environment and shells

Project and repo environment is plain dotenv. It is loaded explicitly by `env`,
`shell` and `shell -c`; gitspace's own git commands never load it.

```text
<project.path>/.env              project values, exportable
<project.path>/.env.secrets      project secrets, mode 600, keys only in bundles
<checkout.path>/.env             repo values, may be committed
<checkout.path>/.env.local       repo-local secrets, gitignored
```

Layer order, lowest to highest: project `.env`, repo `.env`, project
`.env.secrets`, repo `.env.local`, process environment, `GITSPACE_*`. Secrets
override same-named non-secrets; the process environment wins over files.

```sh
gitspace project env edit demo          # $VISUAL/$EDITOR, else vi; needs a TTY
gitspace project env ls demo            # keys and values
gitspace project env path demo          # print the .env path

gitspace project secret edit demo       # .env.secrets, mode 600
gitspace project secret ls demo         # keys only
gitspace project secret ls demo --values
gitspace project secret path demo

gitspace env demo@4711:api              # keys and sources, no values
gitspace env demo@4711:api --values     # resolved values
gitspace env demo@4711:api --shell      # export lines
gitspace shell demo@4711:api            # interactive shell
gitspace shell demo@4711:api -c "mix test"
```

`env` and `shell` use the same resolver; no shell is needed to inspect the
resolved values. `${VAR}` interpolation uses the process environment and the
`GITSPACE_*` context. Command substitution is rejected.

`GITSPACE_*` values set for children: `PROJECT`, `TOPIC`, `WORKSPACE`, `MEMBER`,
`REPO`, `BRANCH`, `PATH`, `IDENTITY`.

`config export` includes project `.env` values and secret **keys only**; import
writes `.env` and `.env.secrets.example` for new projects. Repo files are never
part of a bundle.

For many checkouts, `ls --paths` and `workspace ls --paths` print one path per
line, ready for fzf:

```sh
gitspace shell "$(gitspace ls --paths | fzf)"
cd "$(gitspace path demo@4711:api)"
```

## Changing remote URLs

`repo set-url` changes the mirror's fetch URL. `--push` changes the push URL instead; on a
local repository the first call adopts an upstream and fetches once (`--no-fetch` opts out).
The identity and mirror directory never change:

```sh
gitspace repo set-url ferroclass git@github.com:jansenm/ferroclass.git
gitspace repo set-url ferroclass git@gitlab.com:jansenm/ferroclass.git
gitspace repo set-url ferroclass git@github.com:jansenm/ferroclass.git --push
```

A repository's identity is immutable, so any host, port or path may change: the mirror
directory, index rows, project members and markers all keep referring to the same repository.
Only an address that already belongs to another repository is refused. A remote with several
fetch or push URLs is also refused instead of guessing which one to replace.

## Labels and descriptions

Labels belong to **workspaces**; a description exists on workspaces and projects. Labels are
free-form, trimmed and unique, and they live in the workspace marker, so they survive a
reindex. There is no editor: everything is explicit parameters, which keeps it usable from
scripts and agents.

```sh
gitspace workspace label add vemags@4711 jira-123 review
gitspace workspace label rm vemags@4711 review
gitspace workspace label set vemags@4711 jira-123     # replace the whole set
gitspace workspace label set vemags@4711              # clear all labels
gitspace workspace label ls vemags@4711

gitspace workspace edit vemags@4711 --description "move the deploy job"
gitspace workspace edit vemags@4711 --clear-description

gitspace project edit vemags --description "VEMAGS services"
gitspace project edit vemags --clear-description
```

`gitspace ls --label review` filters by label. `gitspace show <workspace>` displays labels and
the description; `status` deliberately shows only live state.

## Removing workspaces

```sh
gitspace workspace rm vemags@MT4711          # every member, then the workspace
gitspace workspace rm vemags@MT4711:api      # one member
gitspace workspace rm vemags@MT4711 --delete-branch
gitspace workspace rm vemags@MT4711 --delete-branch --force   # anchor local-only commits first
gitspace workspace rm vemags@MT4711 --dry-run
```

- Owned members are removed as git worktrees; borrowed members are unlinked and their
  checkouts stay in place (only the symlink in the workspace is removed).
- Removing the last member tombstones the workspace. The project definition remains; its
  directory is removed too when nothing but the gitspace project marker is left in it.
- Risky owned members (dirty, untracked, or unpushed work) are refused. `--force` anchors
  HEAD and saves the tracked diff plus untracked files under `<data>/trash` before removal.
- Branches are kept by default and reported as `branches kept`, in `--dry-run` and after
  removal, so nothing disappears silently. `--delete-branch` deletes each owned local branch
  whose tip is already reachable from a remote-tracking ref, a tag or another local branch.
  The default branch and branches checked out elsewhere are never deleted. With
  `--force --delete-branch`, a branch with commits that exist only here is anchored under
  `refs/gitspace/keep/branch/…` and then deleted. The remote branch and the push target are
  never touched.
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
workspace handles, bare topics, project members and config keys. Compound targets are
completed segment by segment (`project/`, `project/topic/`, `project@topic:`,
`project@topic/member`), so shell scripts, workspace commands and `status` share the same
addressing forms. They call the hidden `gitspace __complete` command, so they follow the
live index rather than a static snapshot.

Starting the BEAM costs more than the lookup, so the generated scripts memoize each
context and `__complete` keeps a snapshot next to the config file
(`config.toml.complete.json`). Mutating commands bump `config.toml.stamp`, which invalidates
both caches. A cache hit answers in a few milliseconds; only the first Tab after a change
pays for a new process.

## Listing

`gitspace ls` is compact by default: project, topic, member, branch, dirty/ahead/behind/
unpushed counts, and age. It intentionally omits paths and mirror details so a normal table
fits in roughly 100 characters.

```sh
gitspace ls
gitspace ls --verbose      # adds HASH and MIRROR
gitspace ls --project P    # one project
gitspace ls --topic T      # one topic across projects
gitspace ls --refresh      # recompute git status, no fetch
gitspace ls --json         # full rows, including path and mirror metadata
```

A `?` in a count means the cached status is missing or older than
`status.max_age_seconds` (default 3600). `gitspace ls --refresh` recomputes the listed
checkouts; `gitspace --refresh` recomputes every indexed checkout before rendering the inbox.
`repo fetch --all` prints one progress line per repository (`fetching 1/2 demo ... ok`) as it
completes; `--json` remains a single document. `repo fetch` is not a status refresh: fetching
invalidates `last_status_at` and can make more `?` appear until a `status`/`ls --refresh` runs.

Long local operations report progress inline in text mode: `gitspace --refresh`,
`gitspace ls --refresh`, `gitspace status <workspace|project|repo> --refresh`, and
`gitspace doctor fix`/`doctor reindex`. `--json` is always silent and stays a single document.

### show vs status

- `gitspace show <target>` is the identity and definition: project, workspace, repo, branch,
  head, path, membership, and for projects/repos their members and workspaces.
- `gitspace status <target>` is the live state: dirty and untracked files, ahead/behind,
  unpushed commits, an operation in progress, risk, age, and with `--long`/`--diff` the files
  and patch.
- `gitspace ls` is the plural checkout inventory. `gitspace` is the inbox. There is no
  `status` without a target.

Use `gitspace path <target>` or `gitspace show <target>` when the checkout path is what you
need. `gitspace show .` (and `gitspace status .`) resolves the current directory, including
subdirectories, and prints `project`, `workspace` and `repo`; `--json` exposes the same fields.

## History and diffs

`gitspace log <target>` shows both sides of a checkout's divergence:

```sh
gitspace log vemags@JENKINS-123:api            # outgoing and incoming
gitspace log vemags@JENKINS-123:api --outgoing # what a push would send
gitspace log vemags@JENKINS-123:api --incoming # what a rebase would integrate
gitspace log repo:api --fetch --json           # refresh the mirror first
```

Outgoing commits use the same range as `unpushed`: `@{u}..HEAD`, or "not on any remote or
tag" when no upstream exists. Incoming uses `HEAD..@{u}`; without an upstream it falls back
to `origin/<default>` and labels that base. The default limit is `log.max_commits` (10) per
direction and member; `--limit N` overrides it and `--all` shows everything. Counts remain
visible when a list is truncated.

For a single member or checkout, `status` can show the working tree:

```sh
gitspace status vemags@JENKINS-123:api --long   # changed and untracked paths
gitspace status vemags@JENKINS-123:api -v       # staged and unstaged patches
gitspace status vemags@JENKINS-123:api -v --diff-lines 0
```

`--long`/`-l` lists file entries; `--diff`/`-v` adds the patch and implies `--long`. Diffs
are capped at 200 lines per side by default, and `--diff-lines 0` removes the cap. Both need
a single member or checkout target.

## Publishing

```sh
gitspace push vemags@JENKINS-123:api                    # push the checked-out branch
gitspace push vemags@JENKINS-123 --dry-run              # all owned members, no changes
gitspace push vemags@JENKINS-123:api --remote up        # choose the remote
gitspace push vemags@JENKINS-123:api --force-with-lease # after a rebase
```

A push targets the same-named remote branch (`HEAD:refs/heads/<branch>`) and sets that branch
as the upstream. A branch that tracks a differently named upstream is never pushed to that
upstream; the mismatch is reported and the tracking is updated to the pushed branch. The
remote is the configured upstream's remote, otherwise `origin`, otherwise the only remote;
multiple candidates require `--remote`. Borrowed members are skipped, detached checkouts and
checkouts without a remote are refused. A non-fast-forward push is rejected unless
`--force` or `--force-with-lease` is given. After a rebase, prefer
`--force-with-lease`: it only rewrites while the local remote-tracking ref still matches the
remote, so fetch first for a current lease. `--force` skips that check and can overwrite remote
work. The two flags are mutually exclusive; `--dry-run` works with either. After a successful
push the status cache is refreshed.

New owned branches created by `co --topic` or `workspace new` are configured to push to the
same-named remote branch (`branch.<name>.remote`/`merge`) at creation time, so a plain
`git push` works with a normal `push.default` even before that remote branch exists. Until
the first push or fetch, gitspace treats the not-yet-existing upstream as absent, so the
unpushed count still includes every commit that exists nowhere else. Existing branches keep
their tracking; the first `gitspace push` corrects a mismatched upstream.

## Rebasing

```sh
gitspace rebase                        # every managed worktree
gitspace rebase vemags@JENKINS-123     # owned members of one workspace
gitspace rebase vemags@JENKINS-123:api --fetch
gitspace rebase --continue             # every worktree with a rebase in progress
gitspace rebase --abort --yes          # abort and roll back the last batch
gitspace rebase --abort vemags@JENKINS-123:api
```

Each worktree is rebased independently onto the ref it was derived from. A topic branch
created from `main` therefore rebases onto `origin/main`, not onto its own same-named remote
branch, even after that branch has been pushed. The base is recorded as
`branch.<name>.gitspace-base` when the branch is created; plain checkouts fall back to their
configured upstream. A branch whose push target does not exist yet is reported up to date with
a push hint instead of failing, so a fresh topic branch never blocks a batch.

A failure is reported per worktree and the remaining ones are still attempted. Conflicts are
left in place with the conflicting files and progress (`1/3`): resolve them, `git add`, then
`--continue`, or `--abort`. Starting requires a clean tree, an attached branch and no
merge/rebase/cherry-pick/revert in progress. `--fetch` refreshes the mirrors before starting.
Batch abort requires `--yes`.

`--abort` stops in-progress rebases and also **rolls back completed rebases from the last
batch** (journal at `<data>/rebase.json`). Rollback only happens while the worktree is still
at the recorded post-rebase head and the tree is clean; otherwise that entry is skipped, so
new commits or local changes are never discarded. Before resetting, the pre-rebase head is
anchored under `refs/gitspace/keep/rebase/…`. A targeted abort needs no confirmation.

The base is recorded per branch and can be changed without fetching or rebasing:

```sh
gitspace base vemags@JENKINS-123              # show branch, base and source
gitspace base vemags@JENKINS-123 origin/main
gitspace base vemags@JENKINS-123:api origin/release/2.4
gitspace base repo:vemags origin/develop      # every checkout of that repo
gitspace base vemags@JENKINS-123 --clear      # fall back to the git upstream
```

`base` writes `branch.<name>.gitspace-base` in each owned checkout, so every repository
keeps its own ref. The change applies to the next `gitspace rebase` and to
`gitspace log --incoming`; it does not touch the push target (`branch.<name>.merge`).

`gitspace status` prints `operation: rebase in progress (2/5) onto …` while a merge, rebase,
cherry-pick or revert is in progress. `ls` and the inbox add the operation to the risk
reasons. The state is read from the worktree's git dir, so no index migration is needed.
The temporary anchor used during rollback is removed again after a successful reset.

## Keep refs

Teardown and `doctor fix` anchor commits under `refs/gitspace/keep/…` before removing a
worktree or pruning stale metadata. They are real backups, not garbage, so gitspace never
deletes them silently:

```sh
gitspace doctor keep ls --verbose                 # repo, kind, age, redundant/kept, commit
gitspace doctor keep prune                        # delete redundant anchors only
gitspace doctor keep prune --older-than 30 --yes  # also orphaned anchors older than 30 days
gitspace doctor keep prune --dry-run              # preview only
```

A redundant anchor points at a commit that is still reachable from a branch, remote or tag;
deleting it loses nothing. An orphaned anchor is the only remaining reference to removed
work: it is kept unless `--older-than` is explicit, and that asks for confirmation. `doctor`
reports redundant anchors and `--fix` prunes those automatically.

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
- **Git floor:** 2.42 (`worktree add --orphan` for local repositories).
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
- `doctor fix` prunes worktree metadata; use `doctor reindex` to reconcile missing checkout rows.
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
