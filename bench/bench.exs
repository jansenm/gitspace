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

tmp_base = System.get_env("GITSPACE_BENCH_DIR") || System.tmp_dir!()
File.mkdir_p!(tmp_base)

tmp = Path.join(tmp_base, "gitspace-bench-#{System.system_time(:millisecond)}")
File.rm_rf!(tmp)
File.mkdir_p!(tmp)

count =
  System.get_env("GITSPACE_BENCH_WORKTREES", "20")
  |> String.to_integer()

source =
  case System.get_env("GITSPACE_BENCH_REPO") do
    nil -> synthetic_repo.(Path.join(tmp, "src"))
    path -> Path.expand(path)
  end

IO.puts("source: #{source}")
IO.puts("worktrees: #{count}")
IO.puts("")

bare = Path.join(tmp, "mirror.git")

time.("mirror init + fetch", fn -> Mirror.init!(bare, source) end)

ref = "origin/#{Mirror.default_branch(bare) || "main"}"
IO.puts("default ref: #{ref}")
IO.puts("")

paths =
  for i <- 1..max(count, 1) do
    path = Path.join([tmp, "wts", "wt-#{i}"])
    File.mkdir_p!(Path.dirname(path))

    label = if i == 1, do: "co (one worktree)", else: "co (worktree #{i})"

    {:ok, _} = time.(label, fn -> Worktree.add(bare, path, ref, detach: true) end)
    path
  end

time.("worktree list (#{count})", fn -> Worktree.list!(bare) end)
time.("status (#{count})", fn -> Enum.each(paths, &Status.read!/1) end)

File.rm_rf!(tmp)
