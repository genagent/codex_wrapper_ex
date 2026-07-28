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

## Codex CLI compatibility

Tested against codex-cli 0.145.0.

The Codex CLI moves quickly and has removed flags between releases, so a
wrapper release is only known to match the version recorded here. Subcommands
this wrapper does not cover -- including the experimental `app-server`,
`remote-control`, `cloud`, and `exec-server` -- are reachable through
[`CodexWrapper.raw/1`](#raw-cli-escape-hatch):

```elixir
CodexWrapper.raw(["some", "new", "subcommand"])
```

Keeping the version current is part of the release checklist: bump the line
above whenever the wrapper is verified against a newer CLI. The weekly
`CLI contract` workflow installs the latest `@openai/codex` and runs
`mix codex.contract`, opening a `cli-drift` issue when the wrapper emits a
flag the CLI no longer accepts.

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

`search/1` enables live web search and `search/2` selects a mode
(`:cached`, `:indexed`, `:live`, `:disabled`):

```elixir
Exec.new("What changed in OTP 27?")
|> Exec.search(:cached)
|> Exec.execute(config)
```

Both emit `-c web_search="<mode>"`. The Codex CLI removed the `--search`
flag from `exec` in 0.14x; the config key is the supported equivalent,
and `:live` is what `--search` used to mean.

`profile/2` selects a named config profile, emitting `--profile <name>`.
The CLI loads the matching `[profiles.<name>]` section of `config.toml`:

```elixir
Exec.new("Fix the tests")
|> Exec.profile("fast")
|> Exec.execute(config)
```

It is available on `Exec` only, and as a `:profile` option on
`CodexWrapper.exec/2` and `CodexWrapper.Session.new/2`. The Codex CLI
accepts `--profile` on `codex exec` but rejects it on `codex exec resume`
and `codex exec review`, so `ExecResume` and `Review` have no `profile/2`,
and a session's `:profile` applies to its first turn only.

### Config isolation

By default the CLI loads `$CODEX_HOME/config.toml`, so a programmatic run
silently inherits whatever the developer has configured. Two options take
that away:

```elixir
Exec.new("Summarize the diff")
|> Exec.ignore_user_config()
|> Exec.strict_config()
|> Exec.config(~s(model="o3"))
|> Exec.execute(config)
```

`ignore_user_config/1` skips the config file entirely (auth still
resolves through `CODEX_HOME`). `strict_config/1` makes the run fail on a
config key this Codex version does not recognize, rather than ignoring
it. Together they give a run whose configuration is exactly what the
caller passed.

`ignore_rules/1` is the same idea for execpolicy `.rules` files.

All three are available on `Exec`, `ExecResume`, and `Review`.

### Hook trust

`dangerously_bypass_hook_trust/1` runs enabled hooks without requiring
persisted hook trust. Hook trust is what stops a repository from running
commands the user never approved, so this belongs only in automation that
already vets where its hooks come from. It is separate from
`dangerously_bypass_approvals_and_sandbox/1`; setting one does not set the
other. Available on `Exec`, `ExecResume`, and `Review`.

### Color and local providers

`color/2` (`:always`, `:never`, `:auto`), `oss/1`, and `local_provider/2`
(`"lmstudio"` or `"ollama"`) are on `Exec` only. `codex exec resume` and
`codex exec review` reject `--color`, `--oss`, and `--local-provider`,
verified against codex-cli 0.145.0.

## Review builder

```elixir
alias CodexWrapper.{Config, Review}

config = Config.new(working_dir: "/path/to/project")

Review.new()
|> Review.base("main")
|> Review.model("o4-mini")
|> Review.sandbox(:workspace_write)
|> Review.execute(config)
```

`output_schema/2` points `codex exec review` at a JSON Schema file via
`--output-schema`, the same way `Exec.output_schema/2` does, so a review
can return structured output:

```elixir
Review.new()
|> Review.uncommitted()
|> Review.output_schema("/path/to/schema.json")
|> Review.execute(config)
```

`full_auto/1` is still available on `Exec`, `ExecResume` and `Review`,
but it is deprecated upstream: it now selects the `workspace-write`
sandbox rather than emitting the deprecated `--full-auto` flag. An
explicit `sandbox/2` call wins over it.

`sandbox/2` works on all three builders but emits different arguments.
`codex exec` takes `--sandbox <mode>`; `codex exec resume` and `codex
exec review` reject that flag with `unexpected argument`, so on
`ExecResume` and `Review` the builder emits the equivalent config
override `-c sandbox_mode="<mode>"` instead. The public API and the
three accepted modes are the same either way.

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

# Add a server that authenticates over OAuth
{:ok, _} = Mcp.add(config, "oauth-server", :http,
  url: "https://example.com/mcp",
  oauth_client_id: "codex-cli",
  oauth_resource: "https://example.com"
)

# Get server details
{:ok, info} = Mcp.get(config, "my-server", json: true)

# Remove a server
{:ok, _} = Mcp.remove(config, "my-server")
```

### MCP OAuth

`login/3` runs the OAuth flow for a configured server and `logout/2` clears
its credentials.

```elixir
{:ok, _} = Mcp.login(config, "oauth-server")
{:ok, _} = Mcp.login(config, "oauth-server", scopes: ["read", "write"])
{:ok, _} = Mcp.logout(config, "oauth-server")
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
{:ok, _} = Auth.login(config, with_access_token: true)
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

## Session lifecycle

`codex archive`, `codex unarchive`, and `codex delete` operate on a saved
session, named by id (UUID) or session name.

```elixir
alias CodexWrapper.Commands.Archive

{:ok, _} = Archive.archive(config, "abc-123")
{:ok, _} = Archive.unarchive(config, "abc-123")
```

`delete` permanently destroys the session, and `unarchive` cannot bring
it back. So it requires an explicit confirmation; without it the CLI is
never invoked.

```elixir
Archive.delete(config, "abc-123")
# => {:error, :confirmation_required}

Archive.delete(config, "abc-123", confirm: true)
# => {:ok, ""}
```

The same three are available on a `%Session{}`, using its session id:

```elixir
{:ok, _} = CodexWrapper.Session.archive(session)
{:ok, _} = CodexWrapper.Session.unarchive(session)
{:ok, _} = CodexWrapper.Session.delete(session, confirm: true)
```

They return `{:error, :no_session}` if no turn has run yet, since the
session id only exists once the CLI has created it.

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

### Runners: process-group cleanup with forcola

Every `codex` subprocess -- the synchronous commands
(`CodexWrapper.exec/2`, `Exec.execute/2`, `ExecResume.execute/2`,
`Review.execute/2`) and the NDJSON streaming paths (`Exec.stream/2`,
`ExecResume.stream/2`, `Review.stream/2`, `Session.stream/3`) -- routes
through a runner module. The default, `CodexWrapper.Runner.Port`, runs `codex` under a
`/bin/sh` wrapper with stdin closed and bounds it with a BEAM `Task`
timeout. On timeout the BEAM task is killed, but no signal reaches the
`codex` process group, so `codex` and any stdio MCP servers it spawned
can survive, reparented to init.

The optional [`forcola`](https://hexdocs.pm/forcola) dependency provides
`CodexWrapper.Runner.Forcola`, which routes runs through a Rust shim that
puts `codex` in its own process group and kills the whole group (SIGTERM
then SIGKILL) on timeout, on close, or when the BEAM dies, so `codex` and
its MCP servers are reaped together. `forcola` is POSIX-only (macOS and
Linux) and ships precompiled shim binaries, so no Rust toolchain is
required.

```elixir
# mix.exs
{:forcola, "~> 0.3"}
```

```elixir
# config/config.exs
config :codex_wrapper, runner: CodexWrapper.Runner.Forcola
```

`:forcola` and `:task` work as shorthand for the two built-in runners.
`:forcola` falls back to the default runner when the dependency is
absent, so it is safe to set unconditionally:

```elixir
config :codex_wrapper, runner: :forcola
```

`CodexWrapper.Runner.Forcola` compiles only when `forcola` is present, so
the dependency stays optional and the default path is unchanged.
`forcola` requires a finite timeout, so when a command's `:timeout` is
`nil` the run falls back to `:forcola_default_timeout_ms` (default
`300_000`) instead of running unbounded:

```elixir
config :codex_wrapper, runner: :forcola, forcola_default_timeout_ms: 120_000
```

#### Streaming through a runner

The streaming paths go through the same selection, so `:forcola` gets
their process group killed too -- on an early `Enum.take/2`, on a
timeout, or when the BEAM dies.

The two runners enforce a command's `:timeout` differently for a stream.
`Runner.Port` treats it as an *idle* bound (the wait for the next line,
what the streaming paths have always used, defaulting to `300_000` when
`:timeout` is `nil`). `Runner.Forcola` treats it as forcola's whole-run
bound, falling back to `:forcola_default_timeout_ms` the same way the
synchronous path does.

A non-zero exit ends a stream without raising on either runner -- the
`Enumerable` simply finishes. Use `execute/2` when the exit code matters.

A custom runner only has to implement `run/4`; `stream_lines/4` is
optional, and a runner without it falls back to `Runner.Port` for
streams.

### Exec options

| Option | Type | Description |
|---|---|---|
| `:model` | `String.t()` | Model name (e.g., `"o3"`, `"o4-mini"`) |
| `:profile` | `String.t()` | Named config profile (`--profile`) |
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
| `:strict_config` | `boolean()` | Fail on unrecognized `config.toml` keys |
| `:ignore_user_config` | `boolean()` | Skip `$CODEX_HOME/config.toml` |
| `:ignore_rules` | `boolean()` | Skip execpolicy `.rules` files |
| `:dangerously_bypass_hook_trust` | `boolean()` | Run hooks without persisted trust |
| `:color` | atom | `:always`, `:never`, or `:auto` (Exec only) |
| `:oss` | `boolean()` | Use an open-source provider (Exec only) |
| `:local_provider` | `String.t()` | `"lmstudio"` or `"ollama"` (Exec only) |

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
| `CodexWrapper.Runner` | Behaviour selecting how subprocesses execute and stream |
| `CodexWrapper.Runner.Port` | Default runner (`/bin/sh` Port with closed stdin) |
| `CodexWrapper.Runner.Forcola` | Optional leak-free runner via `forcola` |
| `CodexWrapper.Commands.Auth` | Authentication (login/logout/status) |
| `CodexWrapper.Commands.Features` | Feature flag management |
| `CodexWrapper.Commands.Mcp` | MCP server CRUD |
| `CodexWrapper.Commands.McpServer` | Run Codex as an MCP server |
| `CodexWrapper.Commands.Sandbox` | Sandboxed command execution |
| `CodexWrapper.Commands.Fork` | Session forking |
| `CodexWrapper.Commands.Apply` | Apply diffs from task IDs |
| `CodexWrapper.Commands.Archive` | Archive, unarchive, and delete saved sessions |
| `CodexWrapper.Commands.Completion` | Shell completion script generation |
| `CodexWrapper.Commands.Version` | CLI version |

## License

MIT -- see [LICENSE](LICENSE).
