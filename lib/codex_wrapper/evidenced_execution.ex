defmodule CodexWrapper.EvidencedExecution do
  @moduledoc false
  alias CodexWrapper.{Config, ExecutionObservation, Result, Runner, SessionObservation}

  @default_output 1_048_576
  @default_timeout 300_000
  @margin 15_000

  def run(mod, command, config, opts) do
    with {:ok, execution} <- observer(opts[:execution_observer], :execution) do
      case prepare(mod, command, config, opts, execution) do
        {:ok, runner, args, session} ->
          collect(runner, config, args, session, execution)

        {:error, _} = error ->
          notify(execution, %ExecutionObservation{outcome: error, termination: :pre_spawn})
          error
      end
    end
  end

  def reject(opts, error) do
    case observer(opts[:execution_observer], :execution) do
      {:ok, target} ->
        notify(target, %ExecutionObservation{outcome: error, termination: :pre_spawn})

      _ ->
        :ok
    end

    error
  end

  defp prepare(mod, command, config, opts, execution) do
    with {:ok, session} <- session_observer(opts),
         runner = Runner.impl(config),
         options = Config.runner_options(config),
         :ok <- supported(runner),
         :ok <- Runner.validate_options(runner, options) do
      wall = Runner.timeout(config) || options[:timeout_ms] || @default_timeout

      unless is_integer(wall) and wall > 0 and wall <= 4_294_967_295,
        do: raise(ArgumentError, "evidenced execution requires a finite positive timeout")

      args = Config.base_args(config) ++ mod.args(%{command | json: true})
      {:ok, runner, args, session}
    end
  catch
    kind, reason ->
      notify(execution, %ExecutionObservation{
        outcome: {:error, {kind, reason}},
        termination: :pre_spawn
      })

      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp supported(runner) do
    cond do
      not (Code.ensure_loaded?(runner) and function_exported?(runner, :run_evidenced, 5)) ->
        {:error, {:evidence_unsupported, runner}}

      function_exported?(runner, :validate_evidence, 0) ->
        runner.validate_evidence()

      true ->
        :ok
    end
  end

  defp observer({pid, ref}, _kind)
       when is_pid(pid) and node(pid) == node() and is_reference(ref), do: {:ok, {pid, ref}}

  defp observer(_, :execution), do: {:error, :invalid_execution_observer}
  defp observer(_, :session), do: {:error, :invalid_session_observer}

  # Explicit atoms avoid creating atoms from caller input.
  defp session_observer(opts) do
    if Keyword.has_key?(opts, :session_observer),
      do: observer(opts[:session_observer], :session),
      else: {:ok, nil}
  end

  defp collect(runner, config, args, session, execution) do
    owner = self()
    ref = make_ref()
    opts = Config.execution_opts(config)
    max_bytes = Keyword.get(opts, :max_output_bytes, @default_output)
    wall = Runner.timeout(config) || Keyword.get(opts, :timeout_ms, @default_timeout)

    bound =
      wall + Keyword.get(opts, :kill_grace_ms, 5_000) +
        Keyword.get(opts, :interrupt_grace_ms, 0) + @margin

    opts =
      opts
      |> Keyword.put_new(:idle_timeout_ms, config.idle_timeout_ms || @default_timeout)
      |> Keyword.put_new(:max_output_bytes, max_bytes)

    # The collector is the only private message target. The runner is linked to
    # it, never to the caller. It monitors the owner and dies with its worker on
    # owner loss. Late output goes to a dead collector rather than the caller.
    {helper, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        owner_ref = Process.monitor(owner)
        collector = self()

        {worker, worker_ref} =
          :erlang.spawn_opt(
            fn ->
              reply =
                try do
                  {:returned,
                   runner.run_evidenced(
                     config.binary,
                     args,
                     opts,
                     Runner.timeout(config),
                     {collector, ref}
                   )}
                catch
                  kind, reason -> {:raised, kind, reason, __STACKTRACE__}
                end

              send(collector, {ref, reply})
            end,
            [:link, :monitor]
          )

        timer = Process.send_after(self(), {ref, :deadline}, min(bound, 4_294_967_295))

        state = %{
          owner: owner,
          owner_ref: owner_ref,
          worker: worker,
          ref: ref,
          session: session,
          buffer: "",
          dropping?: false,
          parsed: nil,
          stdout: "",
          stderr: "",
          bytes: 0,
          max: max_bytes,
          truncated: false
        }

        try do
          loop(state)
        after
          Process.cancel_timer(timer)
          Process.exit(worker, :kill)

          receive do
            {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
          end
        end
      end)

    try do
      await(helper, monitor, ref, execution, session, %{stdout: "", stderr: ""})
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await(helper, monitor, ref, execution, session, partial) do
    receive do
      {^ref, {:partial, channel, prefix}} ->
        partial = Map.update!(partial, channel, &(&1 <> prefix))
        await(helper, monitor, ref, execution, session, partial)

      {^ref, %SessionObservation{} = identity} ->
        notify(session, identity)
        await(helper, monitor, ref, execution, session, partial)

      {^ref, {:done, state, response}} ->
        # Wait for actual helper death before exposing terminal evidence.
        receive do
          {:DOWN, ^monitor, :process, ^helper, _} -> :ok
        end

        finish(state, response, execution)

      {:DOWN, ^monitor, :process, ^helper, reason} ->
        error = {:error, {:io, {:observer_exit, reason}}}

        notify(execution, %ExecutionObservation{
          outcome: error,
          termination: {:observer_exit, reason},
          stdout: partial.stdout,
          stderr: partial.stderr,
          parsed_result: parsed_result(partial.stdout)
        })

        error
    end
  end

  defp loop(state) do
    ref = state.ref
    owner_ref = state.owner_ref
    worker = state.worker

    receive do
      {^ref, {channel, bytes}} when channel in [:stdout, :stderr] and is_binary(bytes) ->
        kept = min(byte_size(bytes), max(state.max - state.bytes, 0))

        if kept > 0 do
          prefix = :binary.copy(binary_part(bytes, 0, kept))
          send(state.owner, {ref, {:partial, channel, prefix}})
        end

        loop(output(state, channel, bytes))

      {^ref, {:returned, response}} ->
        done(state, {:returned, response})

      {^ref, {:raised, _, _, _} = raised} ->
        done(state, raised)

      {^ref, :deadline} ->
        done(
          state,
          {:returned, {{:error, {:io, :observer_deadline}}, %{termination: :observer_deadline}}}
        )

      {:EXIT, ^worker, reason} ->
        done(
          state,
          {:returned,
           {{:error, {:io, {:runner_exit, reason}}}, %{termination: {:runner_exit, reason}}}}
        )

      {:DOWN, ^owner_ref, :process, _, _} ->
        :ok
    end
  end

  defp done(state, response) do
    state = complete_line(state)
    send(state.owner, {state.ref, {:done, state, response}})
  end

  defp output(state, channel, bytes) do
    kept = min(byte_size(bytes), max(state.max - state.bytes, 0))
    prefix = :binary.copy(binary_part(bytes, 0, kept))

    state =
      case channel do
        :stdout -> %{state | stdout: state.stdout <> prefix}
        :stderr -> %{state | stderr: state.stderr <> prefix}
      end

    state = %{
      state
      | bytes: state.bytes + kept,
        truncated: state.truncated or kept < byte_size(bytes)
    }

    if channel == :stdout, do: consume(state, prefix), else: state
  end

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

  defp append(%{dropping?: true} = state, _), do: state

  defp append(state, bytes) do
    if byte_size(state.buffer) + byte_size(bytes) > SessionObservation.max_line_bytes(),
      do: %{state | buffer: "", dropping?: true},
      else: %{state | buffer: state.buffer <> bytes}
  end

  defp complete_line(%{dropping?: true} = state), do: %{state | buffer: "", dropping?: false}

  defp complete_line(state) do
    state =
      case {state.session, SessionObservation.parse(state.buffer)} do
        {nil, _} ->
          state

        {_, nil} ->
          state

        {_, identity} ->
          send(state.owner, {state.ref, identity})
          %{state | session: nil}
      end

    parsed =
      case Jason.decode(state.buffer) do
        {:ok, %{"type" => type} = value} when type in ["turn.completed", "turn.failed"] -> value
        _ -> state.parsed
      end

    %{state | buffer: "", parsed: parsed}
  end

  defp finish(state, {:returned, {outcome, evidence}}, execution) when is_map(evidence) do
    # Output from the terminal result may be more complete than notifications.
    # Both use the same finite combined-prefix bound.
    streams = %{
      state
      | stdout: "",
        stderr: "",
        bytes: 0,
        session: nil,
        buffer: "",
        dropping?: false
    }

    streams = output(streams, :stdout, evidence_stream(evidence, :stdout, state.stdout))
    streams = output(streams, :stderr, evidence_stream(evidence, :stderr, state.stderr))

    streams = complete_line(streams)
    outcome = bounded_result(outcome, streams)

    fields =
      Map.take(evidence, [
        :child_status,
        :child_signal,
        :termination,
        :reason,
        :output_truncated,
        :cleanup,
        :scope,
        :guard_close
      ])
      |> Map.reject(fn {key, value} ->
        is_nil(value) and key not in [:child_status, :child_signal, :reason]
      end)

    observation =
      struct(
        ExecutionObservation,
        Map.merge(fields, %{
          outcome: outcome,
          stdout: streams.stdout,
          stderr: streams.stderr,
          parsed_result: streams.parsed
        })
      )

    observation =
      if state.truncated or streams.truncated,
        do: %{observation | output_truncated: true},
        else: observation

    notify(execution, observation)
    outcome
  end

  defp finish(state, {:raised, kind, reason, stack}, execution) do
    notify(execution, %ExecutionObservation{
      outcome: {:error, {kind, reason}},
      stdout: state.stdout,
      stderr: state.stderr,
      parsed_result: state.parsed,
      termination: {:runner_exception, kind}
    })

    :erlang.raise(kind, reason, stack)
  end

  defp finish(state, _invalid, execution),
    do: finish(state, {:returned, {{:error, {:io, :invalid_evidence}}, %{}}}, execution)

  defp evidence_stream(evidence, key, fallback) do
    case Map.get(evidence, key) do
      bytes when is_binary(bytes) -> bytes
      _ -> fallback
    end
  end

  defp parsed_result(stdout) do
    stdout
    |> :binary.split("\n", [:global])
    |> Enum.reduce(nil, fn line, result ->
      case Jason.decode(line) do
        {:ok, %{"type" => type} = value} when type in ["turn.completed", "turn.failed"] -> value
        _ -> result
      end
    end)
  end

  defp bounded_result({:ok, {_stdout, code, _stderr}}, streams),
    do:
      {:ok,
       %Result{
         stdout: streams.stdout,
         stderr: streams.stderr,
         exit_code: code,
         success: code == 0
       }}

  defp bounded_result(other, _streams), do: other
  defp notify(nil, _), do: :ok
  defp notify({pid, ref}, message), do: send(pid, {ref, message})
end
