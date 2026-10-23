defmodule CodexWrapper.Runner.ForcolaEvidenceContractTest do
  use ExUnit.Case, async: true
  alias CodexWrapper.{Config, Exec, ExecutionObservation, Result, SessionObservation}

  # This coverage intentionally fails when the contract/pin is missing. It is
  # never hidden under test_helper's legacy :forcola availability exclusion.
  # Resolve the installed dependency's shim unless an explicit matching test
  # shim is supplied. Both paths exercise explicit shim_path forwarding.
  @moduletag :forcola_contract
  setup_all do
    assert Code.ensure_loaded?(Forcola.Run),
           "Forcola 0.7 run/2 contract unavailable; install the locked dependency"

    resolved =
      case System.get_env("FORCOLA_SHIM_PATH") do
        nil -> Forcola.Shim.path()
        override -> Forcola.Shim.path(shim_path: override)
      end

    assert {:ok, shim} = resolved,
           "matching Forcola shim unavailable: #{inspect(resolved)}; compile the locked dependency " <>
             "or set FORCOLA_SHIM_PATH to a matching executable"

    assert {:ok, ^shim} = Forcola.Shim.path(shim_path: shim)
    %{shim: shim}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "codex-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{directory: dir, reference: make_ref()}
  end

  test "replacement environment, explicit shim, bounded success and separate cleanup facts",
       ctx do
    config =
      fixture(ctx, "printf '%s' \"${HOME-unset}\"\nprintf diagnostic >&2\n",
        env: [],
        runner_options: [
          shim_path: ctx.shim,
          env_mode: :replace,
          max_output_bytes: 128,
          idle_timeout_ms: 500
        ]
      )

    ref = ctx.reference

    assert {:ok, %Result{stdout: "unset", stderr: "diagnostic", exit_code: 0}} =
             Exec.execute(Exec.new("p"), config, execution_observer: {self(), ref})

    assert_receive {^ref,
                    %ExecutionObservation{
                      child_status: 0,
                      child_signal: nil,
                      cleanup: :confirmed,
                      scope: :process_group,
                      guard_close: :ok,
                      termination: :exit,
                      reason: nil
                    }}

    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "early identity and JSON followed by timeout keep bounded partials and raw terminal evidence",
       ctx do
    script = ~S"""
    printf '%s\n' '{"type":"thread.started","thread_id":"native"}'
    printf '%s\n' '{"type":"turn.completed","usage":{}}'
    while :; do printf x; /bin/sleep 0.01; done
    """

    config = fixture(ctx, script, timeout: 1_000)
    ref = ctx.reference

    assert {:error, {:timeout, 1_000}} =
             Exec.execute(Exec.new("p"), config,
               session_observer: {self(), ref},
               execution_observer: {self(), ref}
             )

    assert_receive {^ref, %SessionObservation{session_id: "native"}}

    assert_receive {^ref,
                    %ExecutionObservation{
                      reason: :timeout,
                      parsed_result: %{"type" => "turn.completed"},
                      cleanup: :confirmed,
                      scope: :process_group,
                      guard_close: :ok,
                      stdout: stdout
                    }}

    assert byte_size(stdout) <= 1_024
    refute_receive {^ref, _}, 20
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "idle and combined output limits are forwarded independently", ctx do
    for {script, option, expected} <- [
          {"printf partial; /bin/sleep 5\n", [idle_timeout_ms: 80], :idle_timeout},
          {"while :; do printf 12345678; printf diagnostic >&2; done\n", [max_output_bytes: 100],
           :max_output_bytes}
        ] do
      config =
        fixture(ctx, script,
          runner_options:
            Keyword.merge(
              [
                shim_path: ctx.shim,
                env_mode: :replace,
                max_output_bytes: 1_024,
                idle_timeout_ms: 500
              ],
              option
            )
        )

      ref = make_ref()

      assert {:error, ^expected} =
               Exec.execute(Exec.new("p"), config, execution_observer: {self(), ref})

      assert_receive {^ref, %ExecutionObservation{reason: ^expected, stdout: out, stderr: err}}
      assert byte_size(out) + byte_size(err) <= (option[:max_output_bytes] || 1_024)
      refute_receive {^ref, _}, 20
    end
  end

  test "INT and native grace are forwarded without a wrapper cancellation loop", ctx do
    marker = Path.join(ctx.directory, "interrupted")

    # Forcola stops collecting output once cancellation begins. A delayed
    # file write proves the INT handler received time to finish before TERM;
    # the terminal observation independently reports child exit and cleanup.
    script = ~S"""
    trap 'exit 42' TERM
    trap '/bin/sleep 0.1; printf interrupted > "$INT_MARKER"; exit 0' INT
    while :; do /bin/sleep 0.01; done
    """

    config =
      fixture(ctx, script,
        timeout: 500,
        env: [{"INT_MARKER", marker}],
        runner_options: [
          shim_path: ctx.shim,
          env_mode: :replace,
          max_output_bytes: 1_024,
          idle_timeout_ms: 2_000,
          interrupt_signal: :int,
          interrupt_grace_ms: 1_000,
          kill_grace_ms: 100
        ]
      )

    ref = ctx.reference

    assert {:error, {:timeout, 500}} =
             Exec.execute(Exec.new("p"), config, execution_observer: {self(), ref})

    assert_receive {^ref,
                    %ExecutionObservation{
                      reason: :timeout,
                      child_status: 0,
                      child_signal: nil,
                      termination: :exit,
                      cleanup: :confirmed,
                      scope: :process_group,
                      guard_close: :ok
                    }}

    assert File.read!(marker) == "interrupted"
    refute_receive {^ref, _}, 20
  end

  test "strict handshake failure does not fabricate child exit or run target", ctx do
    shim = Path.join(ctx.directory, "failed-shim")
    File.write!(shim, "#!/bin/sh\nexit 23\n")
    File.chmod!(shim, 0o755)
    marker = Path.join(ctx.directory, "must-not-exist")

    config =
      fixture(ctx, "touch '#{marker}'\n",
        runner_options: [shim_path: shim, env_mode: :replace, max_output_bytes: 100]
      )

    ref = ctx.reference

    assert {:error, {:spawn, reason}} =
             Exec.execute(Exec.new("p"), config, execution_observer: {self(), ref})

    assert_receive {^ref,
                    %ExecutionObservation{
                      termination: {:spawn, ^reason},
                      child_status: nil,
                      child_signal: nil,
                      cleanup: :unknown,
                      guard_close: :unknown
                    }}

    refute File.exists?(marker)
    refute_receive {^ref, _}, 20
  end

  defp fixture(ctx, script, opts) do
    binary = Path.join(ctx.directory, "target-#{System.unique_integer([:positive])}")
    File.write!(binary, "#!/bin/sh\n" <> script)
    File.chmod!(binary, 0o755)

    Config.new(
      Keyword.merge(
        [
          binary: binary,
          runner: CodexWrapper.Runner.Forcola,
          timeout: 1_000,
          runner_options: [
            shim_path: ctx.shim,
            env_mode: :replace,
            max_output_bytes: 1_024,
            idle_timeout_ms: 500
          ]
        ],
        opts
      )
    )
  end
end
