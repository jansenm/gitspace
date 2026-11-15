Code.compiler_options(ignore_module_conflict: true)

ExUnit.start()

# The developer's global config must never leak into tests. This machine has
# tag.gpgSign = true, which turns `git tag foo` into an error.
System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")
System.put_env("GIT_CONFIG_SYSTEM", "/dev/null")
System.put_env("GIT_TERMINAL_PROMPT", "0")
System.put_env("GIT_AUTHOR_DATE", "2026-01-01T00:00:00 +0000")
System.put_env("GIT_COMMITTER_DATE", "2026-01-01T00:00:00 +0000")
