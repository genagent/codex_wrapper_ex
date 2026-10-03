defmodule CodexWrapper.RunnerSelectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexWrapper.Runner
  alias CodexWrapper.RunnerSelectionTest.OneShotOnlyRunner

  test "loads a configured runner before checking its streaming callback" do
    runner = CodexWrapper.RunnerSelectionTest.LoadableRunner

    directory =
      Path.join(System.tmp_dir!(), "codex-runner-selection-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    [{^runner, beam}] =
      Code.compile_string(~S"""
      defmodule CodexWrapper.RunnerSelectionTest.LoadableRunner do
        @behaviour CodexWrapper.Runner

        @impl true
        def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}

        @impl true
        def stream_lines(_binary, _args, _opts, _timeout), do: ["lazy: hi"]
      end
      """)

    File.write!(
      Path.join(directory, "Elixir.CodexWrapper.RunnerSelectionTest.LoadableRunner.beam"),
      beam
    )

    :code.add_patha(String.to_charlist(directory))

    on_exit(fn ->
      :code.del_path(String.to_charlist(directory))
      :code.purge(runner)
      :code.delete(runner)
      File.rm_rf!(directory)
    end)

    configure_runner(runner)

    :code.purge(runner)
    :code.delete(runner)
    assert :code.is_loaded(runner) == false

    log =
      capture_log(fn ->
        assert ["lazy: hi"] = Runner.stream_lines("echo", ["hi"], [], nil) |> Enum.to_list()
      end)

    assert :code.is_loaded(runner) != false
    assert log == ""
  end

  test "warns when a configured runner lacks stream_lines/4" do
    configure_runner(OneShotOnlyRunner)

    log =
      capture_log(fn ->
        assert ["hi"] = Runner.stream_lines("echo", ["hi"], [], 5_000) |> Enum.to_list()
      end)

    assert log =~ "#{inspect(OneShotOnlyRunner)} does not implement stream_lines/4"
    assert log =~ "falling back to CodexWrapper.Runner.Port"
  end

  test "warns when a configured runner cannot be loaded" do
    configure_runner(CodexWrapper.RunnerSelectionTest.MissingRunner)

    log =
      capture_log(fn ->
        assert ["hi"] = Runner.stream_lines("echo", ["hi"], [], 5_000) |> Enum.to_list()
      end)

    assert log =~ "MissingRunner could not be loaded"
    assert log =~ "falling back to CodexWrapper.Runner.Port"
  end

  test "the default Port runner streams without warning" do
    configure_runner(nil)

    log =
      capture_log(fn ->
        assert ["hi"] = Runner.stream_lines("echo", ["hi"], [], 5_000) |> Enum.to_list()
      end)

    assert log == ""
  end

  defp configure_runner(runner) do
    previous = Application.fetch_env(:codex_wrapper, :runner)

    if runner == nil do
      Application.delete_env(:codex_wrapper, :runner)
    else
      Application.put_env(:codex_wrapper, :runner, runner)
    end

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:codex_wrapper, :runner, value)
        :error -> Application.delete_env(:codex_wrapper, :runner)
      end
    end)
  end

  defmodule OneShotOnlyRunner do
    @moduledoc false
    @behaviour CodexWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}
  end
end
