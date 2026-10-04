defmodule CodexWrapper.ObservedExecution do
  @moduledoc """
  Shared opt-in execution for fresh, resumed and forked commands.

  Pass `session_observer: {local_pid, reference}` to `Exec.execute/3`,
  `ExecResume.execute/3`, `ExecFork.execute/3` or `ExecFork.fork/3`.
  Existing `CodexWrapper.exec/2` and `exec_json/2` accept the same option.
  Observed commands force `--json` and require a runner implementing
  `c:CodexWrapper.Runner.run_observed/5`; no Port fallback occurs.

  Only the first valid stdout `thread.started` with a nonblank `thread_id`
  produces a `CodexWrapper.SessionObservation`. Malformed, duplicate and
  conflicting later announcements are ignored. Stderr cannot supply identity.
  A dead observer is harmless. The execution caller sends the observation
  before returning, preserving order with its later reply to that observer.

  Results retain every byte in separate stdout and stderr fields. Legacy
  `execute/2` keeps its merged output. Exit codes and process success semantics
  are unchanged, including a successful process with no thread announcement.
  Completion waits for the transport, not a JSON event. The configured
  whole-run timeout and runner cleanup apply; no new idle timeout is added.

  Identity framing uses at most 1 MiB per line. Oversized lines are ignored
  until the next newline without changing final raw output. Observer targets
  and runner support are checked before spawning. Invalid options return
  `{:error, :invalid_session_observer}`; unsupported runners return
  `{:error, {:observation_unsupported, runner}}`.
  """

  alias CodexWrapper.{Config, Result, Runner, SessionObservation}

  @doc false
  @spec run(module(), struct(), Config.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(mod, command, config, opts) do
    with {:ok, observer} <- observer(opts),
         {:ok, runner} <- observed_runner() do
      args = Config.base_args(config) ++ mod.args(%{command | json: true})
      collect(runner, config, args, observer)
    end
  end

  defp observer(session_observer: {pid, reference})
       when is_pid(pid) and node(pid) == node() and is_reference(reference),
       do: {:ok, {pid, reference}}

  defp observer(_opts), do: {:error, :invalid_session_observer}

  defp observed_runner do
    runner = Runner.impl()

    if Code.ensure_loaded?(runner) and function_exported?(runner, :run_observed, 5) do
      {:ok, runner}
    else
      {:error, {:observation_unsupported, runner}}
    end
  end

  defp collect(runner, config, args, observer) do
    caller = self()
    reference = make_ref()
    task = Task.async(fn -> invoke(runner, config, args, {caller, reference}) end)
    state = %{observer: observer, buffer: "", dropping?: false}

    try do
      await(task, reference, state, runner, config.timeout)
    after
      Task.shutdown(task, :brutal_kill)
      flush(reference)
      flush(task.ref)
    end
  end

  # The owned Task contains transport exceptions/throws until the execution
  # caller can reproduce them after cleanup. It must never crash its link
  # incidentally before the caller has drained prior observation messages.
  defp invoke(runner, config, args, target) do
    {:returned,
     runner.run_observed(config.binary, args, Config.cmd_opts(config), config.timeout, target)}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp await(task, reference, state, runner, timeout) do
    task_ref = task.ref

    receive do
      {^reference, {:stdout, bytes}} ->
        await(task, reference, consume(state, bytes), runner, timeout)

      {^reference, {:stderr, _bytes}} ->
        await(task, reference, state, runner, timeout)

      {^task_ref, {:returned, outcome}} ->
        finish(state)
        result(outcome, runner, timeout)

      {^task_ref, {:raised, kind, reason, stacktrace}} ->
        finish(state)
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        {:error, {:io, {:runner_exit, reason}}}
    end
  end

  defp result({:ok, {stdout, code, stderr}}, _runner, _timeout),
    do: {:ok, %Result{stdout: stdout, stderr: stderr, exit_code: code, success: code == 0}}

  defp result({:error, :timeout}, runner, timeout),
    do: {:error, {:timeout, Runner.effective_timeout(runner, timeout)}}

  defp result({:error, _reason} = error, _runner, _timeout), do: error

  defp consume(%{observer: nil} = state, _bytes), do: state

  defp consume(state, bytes) do
    case :binary.match(bytes, "\n") do
      :nomatch ->
        append(state, bytes)

      {index, 1} ->
        line = binary_part(bytes, 0, index)
        rest = binary_part(bytes, index + 1, byte_size(bytes) - index - 1)
        state |> append(line) |> complete_line() |> consume(rest)
    end
  end

  defp append(%{dropping?: true} = state, _bytes), do: state

  defp append(state, bytes) do
    if byte_size(state.buffer) + byte_size(bytes) > SessionObservation.max_line_bytes() do
      %{state | buffer: "", dropping?: true}
    else
      %{state | buffer: state.buffer <> bytes}
    end
  end

  defp complete_line(%{dropping?: true} = state), do: %{state | dropping?: false, buffer: ""}
  defp complete_line(%{observer: nil} = state), do: state

  defp complete_line(state) do
    case SessionObservation.parse(state.buffer) do
      nil ->
        %{state | buffer: ""}

      observation ->
        {pid, reference} = state.observer
        send(pid, {reference, observation})
        %{state | observer: nil, buffer: ""}
    end
  end

  defp finish(state), do: complete_line(state)

  defp flush(reference) do
    receive do
      {^reference, _message} -> flush(reference)
    after
      0 -> :ok
    end
  end
end
