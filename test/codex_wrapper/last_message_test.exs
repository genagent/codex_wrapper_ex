defmodule CodexWrapper.LastMessageTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, Exec, ExecFork, ExecResume, LastMessage, Result, Review}

  @fake Path.expand("../fixtures/fake_codex_last_message", __DIR__)

  defmodule InspectRunner do
    def run(mode, args, _opts, _timeout) do
      index = Enum.find_index(args, &(&1 == "--output-last-message"))
      path = Enum.at(args, index + 1)
      send(self(), {:path, path, File.stat!(path)})

      case mode do
        "raise" ->
          raise "runner failed"

        "error" ->
          {:error, :synthetic}

        "read_error" ->
          {:ok, {"noise", 0}}

        "ok" ->
          File.write!(path, "private message")
          {:ok, {"noise", 0}}
      end
    end

    def run_observed(mode, args, opts, timeout, {caller, reference}) do
      unless "--json" in args, do: raise("expected observed execution")
      send(caller, {reference, {:stdout, ~s({"type":"thread.started","thread_id":"fake"}\n)}})
      {:ok, {stdout, code}} = run(mode, args, opts, timeout)
      {:ok, {stdout, code, "separate stderr"}}
    end
  end

  defp run_fake(scenario, command \\ Exec.new("summarize")) do
    calls =
      Path.join(System.tmp_dir!(), "last-message-calls-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(calls) end)

    config =
      Config.new(
        binary: @fake,
        timeout: 10_000,
        env: [{"FAKE_CODEX_CALLS", calls}, {"FAKE_CODEX_SCENARIO", scenario}]
      )

    outcome = LastMessage.run(command, config)
    path = calls |> File.read!() |> String.trim_trailing()
    {outcome, path}
  end

  test "returns exact final text for all four commands and removes owned files" do
    for command <- [Exec.new("x"), ExecResume.new(), ExecFork.new("source-thread"), Review.new()] do
      assert {{:ok, "final message\n", %Result{exit_code: 0} = result}, path} =
               run_fake("success", command)

      assert result.stdout =~ "stdout noise"
      assert result.stdout =~ "stderr noise"
      refute File.exists?(path)
    end
  end

  test "missing and empty successful output is no_last_message" do
    for scenario <- ["missing", "empty"] do
      assert {{:error, {:no_last_message, %Result{exit_code: 0}}}, path} = run_fake(scenario)
      refute File.exists?(path)
    end
  end

  test "nonzero exits retain text and result, including missing and empty files" do
    for {scenario, text} <- [
          {"failed", "final message\n"},
          {"failed_missing", ""},
          {"failed_empty", ""}
        ] do
      assert {{:error, {:process_failed, ^text, %Result{exit_code: 2}}}, path} =
               run_fake(scenario)

      refute File.exists?(path)
    end
  end

  test "explicit paths remain the caller's for every command" do
    path = Path.join(System.tmp_dir!(), "caller-message-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    for command <- [Exec.new("x"), ExecResume.new(), ExecFork.new("source-thread"), Review.new()] do
      command = %{command | output_last_message: path}
      assert {{:ok, "final message\n", _result}, ^path} = run_fake("success", command)
      assert File.read!(path) == "final message\n"
    end
  end

  test "passes observation options through and preserves the result" do
    config = Config.new(binary: "ok", runner: InspectRunner)
    reference = make_ref()

    assert {:ok, "private message", %Result{stdout: "noise", stderr: "separate stderr"}} =
             LastMessage.run(Exec.new("x"), config, session_observer: {self(), reference})

    assert_received {^reference, %CodexWrapper.SessionObservation{session_id: "fake"}}
  end

  test "read errors retain the original result and explicit path" do
    config = Config.new(binary: "read_error", runner: InspectRunner)
    command = Exec.new("x") |> Exec.output_last_message(__DIR__)

    assert {:error, {:last_message_read, :eisdir, %Result{exit_code: 0}}} =
             LastMessage.run(command, config)

    assert File.dir?(__DIR__)
  end

  test "owned file is private and cleaned on success, runner errors and raises" do
    for mode <- ["ok", "error", "raise"] do
      config = Config.new(binary: mode, runner: InspectRunner)

      case mode do
        "ok" ->
          assert {:ok, "private message", _} = LastMessage.run(Exec.new("x"), config)

        "error" ->
          assert {:error, :synthetic} = LastMessage.run(Exec.new("x"), config)

        "raise" ->
          assert_raise RuntimeError, "runner failed", fn ->
            LastMessage.run(Exec.new("x"), config)
          end
      end

      assert_received {:path, path, stat}
      assert Bitwise.band(stat.mode, 0o777) == 0o600
      assert Path.dirname(path) == Path.expand(System.tmp_dir!())
      refute File.exists?(path)
    end
  end
end
