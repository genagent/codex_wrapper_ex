# CodexWrapperEx

[![CI](https://github.com/genagent/codex_wrapper_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/codex_wrapper_ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/codex_wrapper.svg)](https://hex.pm/packages/codex_wrapper)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/codex_wrapper.svg)](https://hex.pm/packages/codex_wrapper)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/codex_wrapper)
[![License](https://img.shields.io/hexpm/l/codex_wrapper.svg)](https://github.com/genagent/codex_wrapper_ex/blob/main/LICENSE)

Elixir wrapper for the [Codex CLI](https://github.com/openai/codex).

Provides a typed interface for executing prompts, streaming responses,
running code reviews, managing multi-turn sessions, and configuring MCP
servers -- all from Elixir.

## Installation

```elixir
def deps do
  [
    {:codex_wrapper, "~> 0.1.0"}
  ]
end
```

Requires the `codex` CLI to be installed and on your PATH (or set `CODEX_CLI`
to point at it).

## Quick start

```elixir
# One-shot exec
{:ok, result} = CodexWrapper.exec("Explain this error: ...")
IO.puts(result.stdout)

# With options
{:ok, result} = CodexWrapper.exec("Fix the bug in lib/foo.ex",
  model: "o3",
  working_dir: "/path/to/project",
  full_auto: true
)

# Streaming
CodexWrapper.stream("Implement the feature described in issue #42",
  working_dir: "/path/to/project"
)
|> Stream.each(fn event -> IO.inspect(event.event_type) end)
|> Stream.run()
```

## Code review

```elixir
# Review uncommitted changes
{:ok, result} = CodexWrapper.review(uncommitted: true)

# Review against a base branch
{:ok, result} = CodexWrapper.review(base: "main", model: "o4-mini")

# Review a specific commit
{:ok, result} = CodexWrapper.review(commit: "abc123", title: "PR title")
```

## Multi-turn sessions

```elixir
config = CodexWrapper.Config.new(working_dir: "/path/to/project")
session = CodexWrapper.Session.new(config, model: "o3")

{:ok, session, result} = CodexWrapper.Session.send(session, "What files are here?")
{:ok, session, result} = CodexWrapper.Session.send(session, "Add tests for lib/foo.ex")

CodexWrapper.Session.turn_count(session)
#=> 2
```

## IEx REPL

Use Codex conversationally from IEx:

```elixir
iex> import CodexWrapper.IEx

iex> chat("explain this codebase", working_dir: ".", model: "o3")
# => prints response

iex> say("now add tests for the retry module")
# => continues the conversation

iex> cost()
# cost and turn count

iex> history()
# prints full conversation

iex> session_id()
# "abc-123" -- save this to resume later

iex> reset()
# start fresh
```

## Exec builder

For full control, use the `Exec` struct directly:

```elixir
alias CodexWrapper.{Config, Exec}

config = Config.new(working_dir: "/path/to/project")

Exec.new("Fix the tests")
|> Exec.model("o3")
|> Exec.sandbox(:workspace_write)
|> Exec.approval_policy(:never)
|> Exec.search()
|> Exec.execute(config)
```

`approval_policy/2` takes `:untrusted`, `:on_request`, or `:never`, and
emits `-c approval_policy="<value>"`. The Codex CLI removed the
`--ask-for-approval` flag from `exec` in 0.14x; the config key is the
supported equivalent. `:on_failure` was dropped along with the flag and
now raises.

## Review builder

```elixir
alias CodexWrapper.{Config, Review}

config = Config.new(working_dir: "/path/to/project")

Review.new()
|> Review.base("main")
|> Review.model("o4-mini")
|> Review.full_auto()
|> Review.execute(config)
```

## Session resumption

Resume a previous session:

```elixir
alias CodexWrapper.{Config, ExecResume}

config = Config.new()

# Resume a session
ExecResume.new()
|> ExecResume.session_id("previous-session-id")
|> ExecResume.prompt("Continue where we left off")
|> ExecResume.execute(config)

# Resume the most recent session
ExecResume.new()
|> ExecResume.last()
|> ExecResume.execute(config)
```

### Forking

`CodexWrapper.Commands.Fork` was removed. `codex fork` is an interactive
TUI command with no non-interactive path -- piping a prompt to it fails
with `stdin is not a terminal` -- so it cannot be driven from a library.

`ExecResume` is the closest available alternative, but it is **not** a
fork: it resumes a session in place and adds to that session's history,
where forking would branch a new session and leave the original
untouched. There is currently no way to branch a session
non-interactively.

## Retry with backoff

```elixir
alias CodexWrapper.{Config, Exec, Retry}

config = Config.new()
exec = Exec.new("Fix the flaky test")

Retry.execute(exec, config,
  max_retries: 3,
  base_delay_ms: 1_000,
  max_delay_ms: 30_000
)
```

## SessionServer (GenServer)

For OTP applications that need a supervised, process-based session:

```elixir
{:ok, pid} = CodexWrapper.SessionServer.start_link(
  config: config,
  exec_opts: [model: "o3"]
)

{:ok, result} = CodexWrapper.SessionServer.send_message(pid, "Fix the tests")
CodexWrapper.SessionServer.turn_count(pid)
```

Works with supervision trees:

```elixir
children = [
  {CodexWrapper.SessionServer,
   name: :my_agent, config: config, exec_opts: [model: "o3"]}
]
```

## MCP server management

```elixir
alias CodexWrapper.Commands.Mcp

config = CodexWrapper.Config.new()

# List MCP servers
{:ok, servers} = Mcp.list(config, json: true)

# Add a stdio transport server
{:ok, _} = Mcp.add(config, "my-server", :stdio,
  command: "npx",
  args: ["-y", "my-mcp-server"],
  env: %{"API_KEY" => "sk-..."}
)

# Add an HTTP transport server
{:ok, _} = Mcp.add(config, "remote", :http,
  url: "https://example.com/mcp",
  bearer_token_env_var: "MY_TOKEN"
)

# Get server details
{:ok, info} = Mcp.get(config, "my-server", json: true)

# Remove a server
{:ok, _} = Mcp.remove(config, "my-server")
```

## Running Codex as an MCP server

```elixir
alias CodexWrapper.Commands.McpServer

{:ok, output} = McpServer.start(config,
  config: ["key=value"],
  enable: ["feature-name"]
)
```

## Authentication

```elixir
alias CodexWrapper.Commands.Auth

{:ok, _} = Auth.login(config)
{:ok, _} = Auth.login(config, with_api_key: true)
{:ok, _} = Auth.status(config)
{:ok, _} = Auth.logout(config)
```

## Feature flags

```elixir
alias CodexWrapper.Commands.Features

{:ok, list} = Features.list(config)
{:ok, _} = Features.enable(config, "my-feature")
{:ok, _} = Features.disable(config, "my-feature")
```

## Sandbox execution

Run commands inside Codex's sandbox:

```elixir
alias CodexWrapper.Commands.Sandbox

Sandbox.new("python3")
|> Sandbox.args(["script.py", "--flag"])
|> Sandbox.execute(config)
```

Sandbox state and permission profiles:

```elixir
Sandbox.new("pytest")
|> Sandbox.permission_profile("ci")
|> Sandbox.sandbox_state_readable_root("/usr/share")
|> Sandbox.sandbox_state_disable_network()
|> Sandbox.cd("/src")
|> Sandbox.execute(config)
```

`Sandbox.new/1` replaces the old `Sandbox.new(platform, command)`. The
Codex CLI dropped the platform subcommand and infers the platform from
the host, so passing an atom now raises with a migration message.

## Shell completions

```elixir
alias CodexWrapper.Commands.Completion

{:ok, script} = Completion.generate(config, :zsh)
```

## Applying diffs

```elixir
alias CodexWrapper.Commands.Apply

{:ok, _} = Apply.execute(config, "task-id-from-codex")
```

## Raw CLI escape hatch

For subcommands not yet wrapped:

```elixir
CodexWrapper.raw(["some", "new", "subcommand"])
```

## Configuration

### Config options

| Option | Type | Description |
|---|---|---|
| `:binary` | `String.t()` | Path to `codex` binary (auto-discovered if omitted) |
| `:working_dir` | `String.t()` | Working directory for the subprocess |
| `:env` | `[{String.t(), String.t()}]` | Environment variables |
| `:timeout` | `pos_integer()` | Command timeout in milliseconds |
| `:verbose` | `boolean()` | Enable verbose output |

### Process-group cleanup with forcola

By default the one-shot execution path (`Exec.execute/2`,
`ExecResume.execute/2`, `Review.execute/2`, `CodexWrapper.exec/2`) runs
`codex` under a `/bin/sh` wrapper and bounds it with a BEAM `Task`
timeout. On timeout the BEAM task is killed, but the `codex` process it
launched (and any stdio MCP servers `codex` spawned) can survive,
reparented to init.

Adding the optional [`forcola`](https://hexdocs.pm/forcola) dependency
lets you route one-shot runs through a Rust shim that puts `codex` in
its own process group and kills the whole group (SIGTERM then SIGKILL)
on timeout, on close, or when the BEAM dies, so `codex` and its MCP
servers are reaped together. `forcola` is POSIX-only (macOS and Linux)
and ships precompiled shim binaries, so no Rust toolchain is required.

```elixir
# mix.exs
{:forcola, "~> 0.3"}
```

```elixir
# config/config.exs
config :codex_wrapper, runner: :forcola
```

The forcola runner is used only when both the config is set and the
dependency is loaded; otherwise the default runner is unchanged.
`forcola` requires a finite timeout, so when a command's `:timeout` is
`nil` the run falls back to `:forcola_default_timeout_ms` (default
`300_000`) instead of running unbounded:

```elixir
config :codex_wrapper, runner: :forcola, forcola_default_timeout_ms: 120_000
```

The streaming paths (`Exec.stream/2` and friends) still use the
built-in `Port`; forcola-backed streaming is a planned follow-up.

### Exec options

| Option | Type | Description |
|---|---|---|
| `:model` | `String.t()` | Model name (e.g., `"o3"`, `"o4-mini"`) |
| `:sandbox` | atom | `:read_only`, `:workspace_write`, or `:danger_full_access` |
| `:approval_policy` | atom | `:untrusted`, `:on_failure`, `:on_request`, or `:never` |
| `:full_auto` | `boolean()` | Enable full-auto mode |
| `:cd` | `String.t()` | Working directory for codex subprocess |
| `:skip_git_repo_check` | `boolean()` | Skip git repository check |
| `:search` | `boolean()` | Enable live web search |
| `:ephemeral` | `boolean()` | Disable session persistence |
| `:json` | `boolean()` | Enable JSON (NDJSON) output |
| `:output_schema` | `String.t()` | Path to output schema file |
| `:output_last_message` | `String.t()` | Path to save last message |

## Modules

| Module | Description |
|---|---|
| `CodexWrapper` | Convenience API for exec, review, stream, and version |
| `CodexWrapper.Config` | Shared client configuration and binary discovery |
| `CodexWrapper.Exec` | Exec command builder with fluent API |
| `CodexWrapper.ExecResume` | Session resume/continue builder |
| `CodexWrapper.Review` | Code review builder |
| `CodexWrapper.Result` | Parsed command result (stdout, stderr, exit code) |
| `CodexWrapper.JsonLineEvent` | NDJSON streaming event parser |
| `CodexWrapper.Session` | Multi-turn session management |
| `CodexWrapper.SessionServer` | GenServer wrapper for sessions |
| `CodexWrapper.Retry` | Exponential backoff retry |
| `CodexWrapper.IEx` | Interactive REPL helpers |
| `CodexWrapper.Command` | Behaviour for CLI commands |
| `CodexWrapper.Commands.Auth` | Authentication (login/logout/status) |
| `CodexWrapper.Commands.Features` | Feature flag management |
| `CodexWrapper.Commands.Mcp` | MCP server CRUD |
| `CodexWrapper.Commands.McpServer` | Run Codex as an MCP server |
| `CodexWrapper.Commands.Sandbox` | Sandboxed command execution |
| `CodexWrapper.Commands.Fork` | Session forking |
| `CodexWrapper.Commands.Apply` | Apply diffs from task IDs |
| `CodexWrapper.Commands.Completion` | Shell completion script generation |
| `CodexWrapper.Commands.Version` | CLI version |

## License

MIT -- see [LICENSE](LICENSE).
