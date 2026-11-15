# M0 benchmark. Run with:
#
#   mix run bench/bench.exs
#   GITSPACE_BENCH_REPO=/path/to/your/largest/repo mix run bench/bench.exs
#
# The synthetic repo measures overhead. The real repo measures checkout cost.

alias Gitspace.Git
alias Gitspace.Git.{Mirror, Status, Worktree}

time = fn label, fun ->
  {us, result} = :timer.tc(fun)
  IO.puts("#{String.pad_trailing(label, 26)} #{Float.round(us / 1000, 1)} ms")
  result
end

synthetic_repo = fn dir ->
  Git.run!(["init", "--initial-branch=main", dir])
  Git.run!(["config", "user.email", "bench@example.com"], cd: dir)
  Git.run!(["config", "user.name", "Bench"], cd: dir)

  for i <- 1..200 do
    path = Path.join([dir, "src", "dir-#{rem(i, 10)}", "file-#{i}.txt"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "line #{i}\n")
  end

  Git.run!(["add", "-A"], cd: dir)
  Git.run!(["commit", "-m", "initial"], cd: dir)
  Git.run!(["branch", "feature/bench"], cd: dir)
  dir
end

tmp = Path.join(System.tmp_dir!(), "gitspace-bench-#{System.system_time(:millisecond)}")
File.rm_rf!(tmp)
File.mkdir_p!(tmp)

source =
  case System.get_env("GITSPACE_BENCH_REPO") do
    nil -> synthetic_repo.(Path.join(tmp, "src"))
    path -> path
  end

bare = Path.join(tmp, "mirror.git")

time.("mirror init + fetch", fn -> Mirror.init!(bare, source) end)

first = Path.join([tmp, "wts", "first"])
File.mkdir_p!(Path.dirname(first))
time.("co (one worktree)", fn -> Worktree.add(bare, first, "origin/main", detach: true) end)

paths =
  for i <- 1..20 do
    path = Path.join([tmp, "wts", "wt-#{i}"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, _} = Worktree.add(bare, path, "origin/main", detach: true)
    path
  end

time.("worktree list (20)", fn -> Worktree.list!(bare) end)
time.("status (20)", fn -> Enum.each(paths, &Status.read!/1) end)

File.rm_rf!(tmp)
