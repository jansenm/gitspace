# gitspace (M0 spike)

The mechanics spike for a workspace-centric git checkout manager. **Not the product
yet** — this repo currently proves the git and safety mechanics that the v1 plan depends on.

The product scope, CLI surface, acceptance plan and implementation plan live in the planning
repository:

```
/data/mjansen/nextcloud/shared/Dokumente/planning/
├── use-cases/12-v1-scope.md
├── use-cases/13-v1-cli.md
├── use-cases/14-v1-acceptance.md
└── implementation/01-v1-plan.md
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

42 tests, 3 properties, 0.6 s.

## Commands

```sh
mix test
mix compile --warnings-as-errors
mix run bench/bench.exs
GITSPACE_BENCH_REPO=/path/to/real/repo mix run bench/bench.exs
```

## Decisions taken in M0

- **Subprocess:** `Exile` (`stderr: :consume`) because it keeps stdout and stderr separate.
  `MuonTrap` cannot capture both simultaneously.
- **Environment:** `env -u …` per invocation, not mutating the VM environment. Exile inherits
  the parent env and cannot unset; `env -u` is the per-call boundary.
- **Mirror refspec:** `+refs/heads/*:refs/remotes/origin/*`. `git clone --bare` writes no
  refspec on git 2.56.
- **Untracked archive:** system `tar` for Linux v1. `:erl_tar.create/3` does not honour
  `{:cwd, …}` for creation.
- **Test isolation:** `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`, fixed
  author/committer dates. This machine sets `tag.gpgSign = true` globally.

## Not here yet

CLI, config, SQLite/Ecto, workspace creation/teardown, inbox, reindex, prune. That is M1+ in
`implementation/01-v1-plan.md`.
