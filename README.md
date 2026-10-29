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

<!-- x-release-please-start-version -->
```elixir
def deps do
  [
    {:codex_wrapper, "~> 0.8.1"}
  ]
end
```
<!-- x-release-please-end -->

Requires the `codex` CLI to be installed and on your PATH (or set `CODEX_CLI`
to point at it).

## Codex CLI compatibility

Tested against codex-cli 0.149.0 and 0.164.0. Both are pinned in PR CI.

The Codex CLI moves quickly and has removed flags between releases, so a
wrapper release is only known to match the version recorded here. Subcommands
this wrapper does not cover -- including the experimental `app-server`,
`remote-control`, `cloud`, and `exec-server` -- are reachable through
[`CodexWrapper.raw/1`](#raw-cli-escape-hatch):

```elixir
CodexWrapper.raw(["some", "new", "subcommand"])
```

The native contract checks help and closed-enum config rejection without authentication
or model inference. Set `CODEX_CONTRACT_BIN` to select an explicit executable and
`CODEX_CONTRACT_VERSION` to require its reported version. Controlled fake binaries
test that the checker can reject drift; they do not replace these native checks.

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
# turn count; the Codex CLI reports no cost

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

## Structured output

`CodexWrapper.Structured.run/4` takes a JSON Schema as a map, writes it to a
private temporary `--output-schema` file for the life of the process, runs
the command with `--json`, and decodes the final agent message. It accepts
`Exec`, `ExecResume`, `ExecFork` and `Review` commands.

```elixir
schema = %{
  "type" => "object",
  "properties" => %{"name" => %{"type" => "string"}},
  "required" => ["name"],
  "additionalProperties" => false
}

{:ok, %{"name" => name}, %{result: _result, events: _events}} =
  CodexWrapper.Exec.new("Extract the name from: Hi, I'm Ada Lovelace.")
  |> CodexWrapper.Structured.run(schema, config)
```

Codex enforces the schema; the wrapper checks only that the final message is
a JSON object or array. Pass `parse: fn value -> {:ok, ...} | {:error, ...} end`
for a caller-side domain check. Failed turns, non-zero exits, missing terminal
events, missing or invalid messages and parser failures are distinct tagged
errors that keep the result and events. `Structured.decode/2` decodes a
`%Result{}` from a run that used an explicit schema path.

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

`CodexWrapper.ExecFork` wraps `codex exec fork <SESSION_ID> [PROMPT]`. It
copies a session's history into a new session and runs the optional
prompt there. The source session is not modified and can still be
resumed under its original ID.

```elixir
alias CodexWrapper.{Config, ExecFork}

config = Config.new()

{:ok, fork} =
  ExecFork.new("source-session-id")
  |> ExecFork.prompt("Try the other approach")
  |> ExecFork.fork(config)

fork.session_id        # the new session, from the CLI's thread.started event
fork.source_session_id # "source-session-id", unchanged
```

`fork/2` forces `--json` and returns `{:error, {:exit, code, result}}` on a
non-zero exit, for example when the source session does not exist.
`execute/2`, `execute_json/2`, and `stream/2` behave as they do on
`ExecResume`. The session ID is validated before the CLI is spawned:
empty IDs, IDs with surrounding whitespace or control characters, and
IDs starting with `-` return `{:error, {:invalid_session_id, value}}`.

`codex exec fork` accepts the `codex exec resume` flags without `--last`
and `--all`, plus `--output-schema`. It rejects `--sandbox`, so
`sandbox/2` emits `-c sandbox_mode="<mode>"` here as well. Verified
against codex-cli 0.149.0.

A CLI without `exec fork` returns `{:error, {:unsupported, :exec_fork}}`.
`ExecFork.supported?/1` checks ahead of time by running
`codex exec fork --help`. `ExecFork.stream/2` has no error tuple to
return, so on such a CLI enumerating the stream raises
`CodexWrapper.UnsupportedError` with `capability: :exec_fork`. The check
only runs when the stream ends without output.

`codex fork`, without `exec`, only runs as an interactive TUI.
`CodexWrapper.Commands.Fork` wrapped it and was removed.

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

## Diagnostics

`codex doctor` checks the local install, config, auth, and runtime health.
It works as a preflight before a run:

```elixir
alias CodexWrapper.Commands.Doctor

{:ok, report} = Doctor.new() |> Doctor.summary() |> Doctor.execute(config)
```

`execute/2` returns the human-readable report as a string. For the
machine-readable form, `execute_json/2` forces `--json` and decodes it:

```elixir
{:ok, report} = Doctor.new() |> Doctor.execute_json(config)

report["overallStatus"]
#=> "warning"

report["checks"]["auth.credentials"]["status"]
#=> "ok"
```

`codex doctor` exits 0 even when checks report warnings or failures, so a
successful call is not by itself a clean bill of health. Read
`"overallStatus"` rather than relying on the exit code.

Builders: `json/1`, `summary/1`, `all/1`, `no_color/1`, `ascii/1`.

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

## Telemetry

CodexWrapper emits `:telemetry` span events around its core exec paths so
host applications can observe durations and metadata without
re-implementing instrumentation. Each operation produces a matched
`:start`/`:stop` pair, or a `:start`/`:exception` pair if it raises.
Synchronous calls use `:telemetry.span/3`; lazy streams follow the same
event shape over their full consumption lifecycle.

### Events

| Event                                             | Fired around                                                    |
|---------------------------------------------------|-----------------------------------------------------------------|
| `[:codex_wrapper, :exec, :start \| :stop \| :exception]`     | `CodexWrapper.Exec.execute/2`, `CodexWrapper.ExecResume.execute/2`, `CodexWrapper.ExecFork.execute/2` |
| `[:codex_wrapper, :stream, :start \| :stop \| :exception]`   | `CodexWrapper.Exec.stream/2`, `CodexWrapper.ExecResume.stream/2`, `CodexWrapper.ExecFork.stream/2`, `CodexWrapper.Review.stream/2` |
| `[:codex_wrapper, :review, :start \| :stop \| :exception]`   | `CodexWrapper.Review.execute/2`                                 |
| `[:codex_wrapper, :session, :turn, :start \| :stop \| :exception]` | each synchronous `CodexWrapper.Session.send/3` turn (Exec or Resume) |

`execute_json/2` delegates to its corresponding `execute/2` path, so it
emits the same exec or review event rather than an additional
JSON-specific event.

Stream `:start` fires when the returned enumerable is first reduced, not
when it is constructed. `:stop` fires after the producer is exhausted or
the consumer halts early, after producer cleanup has run.

### Metadata

Start metadata (all events):

- `:command` -- atom identifying the command path (`:exec`,
  `:exec_resume`, `:exec_fork`, `:review`, `:session_exec`, or
  `:session_resume`)
- `:session_id` -- session identifier when present (for `:exec_fork`,
  the source session being forked)
- `:sandbox_mode` -- sandbox mode atom (`:read_only`, `:workspace_write`,
  `:danger_full_access`) or `nil`
- `:approval_policy` -- approval policy atom (`:untrusted`, `:on_request`,
  `:never`) or `nil`

Stop metadata adds:

- `:exit_code` -- non-negative integer from the subprocess when a
  synchronous call resolves to a `%CodexWrapper.Result{}`. Streaming
  events omit it because the Runner stream contract does not expose the
  subprocess exit code.

Exception metadata adds the standard `:kind`, `:reason`, and
`:stacktrace` fields.

### Attaching a handler

```elixir
:telemetry.attach_many(
  "codex-wrapper-logger",
  [
    [:codex_wrapper, :exec, :stop],
    [:codex_wrapper, :stream, :stop],
    [:codex_wrapper, :review, :stop],
    [:codex_wrapper, :session, :turn, :stop]
  ],
  fn event, measurements, metadata, _config ->
    require Logger
    Logger.info("#{inspect(event)} duration=#{measurements.duration} meta=#{inspect(metadata)}")
  end,
  nil
)
```

## Configuration

### Config options

| Option | Type | Description |
|---|---|---|
| `:binary` | `String.t()` | Path to `codex` binary (auto-discovered if omitted) |
| `:working_dir` | `String.t()` | Working directory for the subprocess |
| `:env` | `[{String.t(), String.t()}]` | Environment variables |
| `:timeout` | `pos_integer()` | Whole-command timeout in milliseconds; defaults to no whole-run bound for Port streams |
| `:idle_timeout_ms` | `pos_integer() \| nil` | Maximum gap between output frames in a stream; defaults to 300,000 ms, or set `nil` to disable |
| `:runner` | module or shorthand | Per-config runner; snapshots application default when absent |
| `:runner_options` | keyword | Immutable one-shot transport requirements; explicit `[]` overrides application defaults |
| `:verbose` | `boolean()` | Compatibility option: only `false` is supported; `true` raises before CLI execution |

### Observing native thread identity before completion

The opt-in `:session_observer` execution option announces the first valid
stdout `thread.started` ID while a one-shot call is still running:

```elixir
reference = make_ref()
CodexWrapper.exec("continue the work",
  session_observer: {observer_pid, reference},
  working_dir: "/path/to/project", timeout: 300_000)
```

The local observer receives
`{reference, %CodexWrapper.SessionObservation{session_id: id, source: :thread_started}}`.
The execution caller sends this message before returning, so its later terminal
reply to the same observer cannot overtake the observation. Callers own
persistence and must reject references from stale execution attempts. An
observed identity is not proof of completion; the call can still fail or time out.

The same option works with `Exec.execute/3`, `ExecResume.execute/3`,
`ExecFork.execute/3`, `ExecFork.fork/3`, their `execute_json/3` variants and
`CodexWrapper.exec_json/2`. It requires `Runner.Forcola` and Forcola 0.7 or
later in the supported dependency range. Invalid observer options and runners
without observed execution fail before spawning. A dead observer is harmless;
no caller callback runs and no silent Port fallback occurs.

Observed commands force `--json`. Their `Result` preserves every stdout and
stderr byte in separate fields, including final output without a newline.
Legacy `execute/2` and convenience calls without an observer retain merged
output. Exit codes and process success semantics stay the same. Fork identity
comes only from valid stdout `thread.started`, while stderr remains available
for failure diagnostics.

Malformed, blank, duplicate and conflicting later announcements are ignored.
Identity framing is limited to 1 MiB per line; an oversized line is skipped
until the next newline without truncating the final raw result. The whole-run
deadline, including Forcola's configured default for a nil timeout, stays in
force. Completion waits for transport termination even after `turn.completed`.
The execution caller owns and cleans up its helper; owner death closes the
Forcola port and triggers process-group cleanup.

### Evidenced one-shot execution and isolated configuration

`CodexWrapper.Config.new/1` snapshots the application runner and runner options only when
those fields are absent. Explicit `runner_options: []` overrides defaults;
concurrent calls can select different binaries, directories, environment,
models, CLI config/MCP overrides and transport requirements without changing
application or OS state. All one-shot commands, including `raw`, version,
completion and command convenience functions, honor the config's runner.
Directly constructed structs with nil runner fields retain legacy default lookup.
Forcola's legacy one-shot default timeout is captured by `CodexWrapper.Config.new/1` too.

The formerly `System.cmd` commands (auth login/logout/status, apply, completion,
features, MCP, mcp-server and version) now use this runner routing and its timeout
semantics. With the default Port runner they run through `/bin/sh`, with stdin
from `/dev/null` and the SIGINT/TERM/KILL watchdog; a missing binary returns
`{:error, {:exit, 127, output}}` instead of raising. Port has no whole-run bound
unless config `:timeout` is set. Forcola uses the snapshotted
`:forcola_default_timeout_ms` (300,000 ms unless configured) when no explicit
limit is set, then cancels the child and returns `{:error, {:timeout, milliseconds}}`.
Interactive login, device authorization and long-running mcp-server commands
therefore need an explicit config `:timeout` sufficient for the intended wait or
server lifetime under Forcola. This routing does not supply interactive stdin
or a duplex MCP connection.

Add `execution_observer` to `Exec.execute/3`, `ExecResume.execute/3`,
`ExecFork.execute/3`, `ExecFork.fork/3`, `Review.execute/3`, JSON variants,
or the exec/review convenience functions. Supply a `session_observer` too
when early native identity is needed:

```elixir
ref = make_ref()
config = CodexWrapper.Config.new(
  binary: "/opt/codex", working_dir: "/work/project",
  env: [{"CODEX_HOME", "/work/config-a"}, {"OPENAI_API_KEY", "caller-supplied"}],
  runner: CodexWrapper.Runner.Forcola,
  timeout: 60_000,
  runner_options: [shim_path: "/opt/forcola_shim", env_mode: :replace,
    idle_timeout_ms: 10_000, max_output_bytes: 1_048_576,
    interrupt_signal: :int, interrupt_grace_ms: 1_000, kill_grace_ms: 500])
CodexWrapper.Exec.execute(CodexWrapper.Exec.new("inspect the project"), config,
  session_observer: {self(), ref}, execution_observer: {self(), ref})
# {ref, %CodexWrapper.SessionObservation{...}}       (if announced)
# {ref, %CodexWrapper.ExecutionObservation{...}}     (exactly once before return)
```

The evidenced adapter requires Forcola `~> 0.7.0`, whose reviewed PR #97
supplies the `run/2` contract and matching shim. The dependency floor has been
updated and the lockfile resolves the published 0.7.0 release.
Forcola 0.6 cannot satisfy this contract and is rejected before evidenced
execution. The example requires the matching trusted shim; fake tests do not
establish native behavior.

A terminal observation preserves bounded stdout/stderr prefixes (including on
failure), the last parsed `turn.completed` / `turn.failed` object, the legacy
outcome, raw child exit/signal, protocol/transport termination, cancellation
reason, truncation, cleanup confirmation/scope, and guard close independently.
Missing facts stay unknown. A session ID, JSON result, exit zero, or exhausted
enumerable does not establish clean completion. Process-group confirmation
says nothing about escaped descendants (Forcola #93 / Codex #119).

Without an explicit limit, evidenced execution uses a finite wall bound: Forcola
uses the snapshotted `:forcola_default_timeout_ms` (300,000 ms unless configured);
other runners use 300,000 ms. Idle defaults to 300,000 ms, with 1 MiB combined
stdout/stderr. `:timeout_ms` supplies a per-config
runner default; `:timeout` takes precedence. Idle/output limits and interrupt
grace must be positive 32-bit integers; kill grace may be zero. Interrupt
signal/grace must be supplied together and only `:int` is accepted. Replacement
environment clears inherited variables even with `env: []`; use an absolute
binary and supply every variable the target requires. Explicit shim paths must
be absolute; installation, matching version and lifetime belong to the caller.

Custom runners opt in with `run_evidenced/5` and may provide
`validate_evidence/0` for capability preflight. `validate_options/1` is required
for nonempty runner options. Unsupported requirements are errors before spawn,
with no Port fallback. A valid execution observer receives a terminal fact
on preflight failure too, without a fabricated child exit. Invalid execution
targets cannot receive a fact. The owned bounded collector forwards identity
from the caller, contains private raw messages, monitors caller/worker death,
and closes before the terminal fact. Forcola remains the native process owner;
there is no competing cancellation loop. Existing session-only observation
and legacy return shapes remain available.

The new controls are one-shot only; streams reject nonempty `runner_options`
and `execution_observer` before spawning. An explicitly selected per-config runner
(including a non-nil runner in a direct struct) must implement `stream_lines/4`;
otherwise stream consumption raises `ArgumentError` before spawning, with no Port
fallback. Implicit application/default runner selection retains the legacy Port
fallback with a warning when the streaming callback is unavailable.

The default `mix test` command includes the required contract suite and resolves
the matching shim from the installed Forcola dependency. To run it alone:

```sh
mix test test/codex_wrapper/runner/forcola_evidence_contract_test.exs
```

An optional `FORCOLA_SHIM_PATH=/absolute/path/to/matching/forcola_shim` test
override selects a trusted executable built for the same Forcola version.
This suite reports a missing contract or shim as a failure and is not excluded
by the legacy `:forcola` availability tag. Fixtures run without Codex credentials
and clean their temporary files; native process cleanup is asserted separately.

### Runners: process-group cleanup with forcola

Every `codex` subprocess -- the synchronous commands
(`CodexWrapper.exec/2`, `Exec.execute/2`, `ExecResume.execute/2`,
`Review.execute/2`) and the NDJSON streaming paths (`Exec.stream/2`,
`ExecResume.stream/2`, `Review.stream/2`, `Session.stream/3`) -- routes
through a runner module. The default, `CodexWrapper.Runner.Port`, runs `codex` under a
`/bin/sh` wrapper with stdin closed and bounds it with a BEAM `Task`
timeout.

When the port closes -- a timeout, a stream idle timeout or early halt, the
owning process dying, or the BEAM dying -- the wrapper's watchdog signals
the `codex` process: SIGINT first, SIGTERM two seconds later, SIGKILL one
second after that, stopping once the process is gone. Codex installs its own
SIGINT handler and uses it to stop tool children it placed in other process
groups. The shell starts `codex` as a background job, which begins with
SIGINT ignored, so a program without such a handler is stopped by the
SIGTERM step. The caller is not held up by this schedule.

This is not a process-tree guarantee. Only the `codex` process is signalled,
so a child that Codex does not stop itself, a daemonized process, or a stdio
MCP server can survive. A process that writes to the closed port can also die
of a broken pipe before its SIGINT handler finishes. Signals are sent by pid,
so a pid reused between the target's exit and the watchdog's cancellation
could be signalled by mistake; the window is kept short, not removed. The
schedule needs an executable `/bin/sleep` to escalate; without one only
SIGINT is sent.

The optional [`forcola`](https://hexdocs.pm/forcola) dependency provides
`CodexWrapper.Runner.Forcola`, which routes runs through a Rust shim that
puts `codex` in its own process group and signals the whole group on
timeout, on close, or when the BEAM dies. One-shot runs send SIGINT first,
SIGTERM after `interrupt_grace_ms` (default 2,000), then SIGKILL after
`kill_grace_ms`; set `interrupt_signal: :int` and `interrupt_grace_ms` in
`runner_options` to change the grace. The SIGINT step matters because codex
puts each tool command and stdio MCP server in its own process group: on
SIGINT codex stops the command it is running, while on SIGTERM alone it
exits and leaves that command behind.

Streaming runs through forcola still send SIGTERM then SIGKILL with no SIGINT
step, because `Forcola.Stream` does not accept interrupt options yet
(joshrotenberg/forcola#93); a tool command running when the stream ends can
outlive codex. Neither runner stops descendants that leave codex's process
group or ignore these signals. On Linux, forcola's cgroup option is the
backstop; on macOS there is none. `forcola` is POSIX-only (macOS and Linux)
and ships precompiled shim binaries, so no Rust toolchain is required.

```elixir
# mix.exs
{:forcola, "~> 0.7.0"}
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
`300_000`) instead of running unbounded for synchronous commands:

```elixir
config :codex_wrapper, runner: :forcola, forcola_default_timeout_ms: 120_000
```

#### Streaming through a runner

The streaming paths go through the same selection, so `:forcola` gets
their process group killed too -- on an early `Enum.take/2`, on a
timeout, or when the BEAM dies.

Both runners use `:timeout` as the whole-run deadline and
`:idle_timeout_ms` as the independent gap between output frames. A
Port stream has no whole-run deadline when `:timeout` is `nil`; a
Forcola stream uses `:forcola_default_stream_timeout_ms` (default
3,600,000 ms) instead. The existing `:forcola_default_timeout_ms`
setting also applies to streams unless the stream-specific setting is
provided. If either
bound expires, the stream emits a final `%CodexWrapper.StreamError{}`
with `{:timeout, ms}` or `{:idle_timeout, ms}` in its `reason` field.
Direct `Runner.stream_lines/4` consumers receive the corresponding
`{:error, reason}` item before the stream ends.

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
| `:approval_policy` | atom | `:untrusted`, `:on_request`, or `:never` |
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
| `CodexWrapper.ExecFork` | Non-interactive session fork builder |
| `CodexWrapper.UnsupportedError` | Raised by a stream when the CLI lacks a capability |
| `CodexWrapper.Review` | Code review builder |
| `CodexWrapper.Result` | Parsed command result (stdout, stderr, exit code) |
| `CodexWrapper.JsonLineEvent` | NDJSON streaming event parser |
| `CodexWrapper.Session` | Multi-turn session management |
| `CodexWrapper.SessionServer` | GenServer wrapper for sessions |
| `CodexWrapper.Retry` | Exponential backoff retry |
| `CodexWrapper.IEx` | Interactive REPL helpers |
| `CodexWrapper.Telemetry` | `:telemetry` span wrappers for exec paths |
| `CodexWrapper.Command` | Behaviour for CLI commands |
| `CodexWrapper.Runner` | Behaviour selecting how subprocesses execute and stream |
| `CodexWrapper.Runner.Port` | Default runner (`/bin/sh` Port with closed stdin and INT/TERM/KILL cleanup of `codex`) |
| `CodexWrapper.Runner.Forcola` | Optional leak-free runner via `forcola` |
| `CodexWrapper.Commands.Auth` | Authentication (login/logout/status) |
| `CodexWrapper.Commands.Features` | Feature flag management |
| `CodexWrapper.Commands.Mcp` | MCP server CRUD |
| `CodexWrapper.Commands.McpServer` | Run Codex as an MCP server |
| `CodexWrapper.Commands.Sandbox` | Sandboxed command execution |
| `CodexWrapper.Commands.Apply` | Apply diffs from task IDs |
| `CodexWrapper.Commands.Archive` | Archive, unarchive, and delete saved sessions |
| `CodexWrapper.Commands.Completion` | Shell completion script generation |
| `CodexWrapper.Commands.Doctor` | Install, config, auth, and runtime diagnostics |
| `CodexWrapper.Commands.Version` | CLI version |

## Testing

The default suite does not invoke an authenticated Codex session:

```bash
mix test
```

Opt-in integration tests exercise the installed Codex CLI, including its
live JSON event shape, session/thread identifier, feature-list format,
and streaming Port path. They require `codex` on `PATH` and an active
login:

```bash
mix test --include integration
# or only the live checks
mix test --only integration
```

The separate CLI contract check is authentication-free and verifies that
the flags and config keys emitted by the wrapper are still accepted:

```bash
mix codex.contract
```

## License

MIT -- see [LICENSE](LICENSE).
