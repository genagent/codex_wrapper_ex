if Code.ensure_loaded?(Forcola) do
  defmodule CodexWrapper.Runner.Forcola do
    @moduledoc """
    Leak-free runner backed by [forcola](https://hex.pm/packages/forcola).

    Every `codex` invocation runs under forcola's Rust shim, which places
    the CLI in its own process group and kills the whole group (SIGTERM,
    then SIGKILL) on timeout or when the BEAM dies. That reaps `codex` and
    every stdio MCP server it spawned together, where the default
    `CodexWrapper.Runner.Port` would leave them running as orphans (see
    #48 and closed #33).

    forcola runs the child one-shot with no stdin writer, so `codex` sees
    EOF naturally -- the `/bin/sh ... < /dev/null` wrapper the default
    runner needs is unnecessary here.

    This module compiles only when `forcola` is a dependency. Select it
    with `config :codex_wrapper, runner: CodexWrapper.Runner.Forcola`.
    forcola is POSIX-only.
    """

    @behaviour CodexWrapper.Runner

    # forcola requires a mandatory whole-run bound. When the caller sets no
    # timeout we still want group-kill-on-BEAM-death, so we pass a very
    # large bound rather than falling back to the leaky path.
    @unbounded_ms 24 * 60 * 60 * 1000

    @impl true
    def run(binary, args, opts, timeout) do
      forcola_opts =
        [timeout_ms: timeout || @unbounded_ms, merge_stderr: merge_stderr?(opts)] ++
          Keyword.take(opts, [:cd, :env])

      case Forcola.run([binary | args], forcola_opts) do
        {:ok, %Forcola.Result{status: status, stdout: stdout}} when is_integer(status) ->
          {:ok, {stdout, status}}

        {:ok, %Forcola.Result{status: {:signal, signal}}} ->
          {:error, {:signal, signal}}

        {:error, {:timeout, _partial}} ->
          {:error, :timeout}

        {:error, {:spawn, reason}} ->
          {:error, {:spawn, reason}}
      end
    end

    defp merge_stderr?(opts), do: Keyword.get(opts, :stderr_to_stdout, false)
  end
end
