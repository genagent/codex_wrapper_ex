defmodule CodexWrapper.ConvenienceStreamTimeoutTest do
  use ExUnit.Case, async: false

  defmodule CaptureRunner do
    @behaviour CodexWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:error, :not_used}

    @impl true
    def stream_lines(_binary, _args, opts, timeout) do
      send(Application.fetch_env!(:codex_wrapper, :capture_parent), {:stream_opts, opts, timeout})
      []
    end
  end

  test "stream/2 forwards the idle and whole-run deadlines independently" do
    previous_runner = Application.get_env(:codex_wrapper, :runner)
    Application.put_env(:codex_wrapper, :runner, CaptureRunner)
    Application.put_env(:codex_wrapper, :capture_parent, self())

    on_exit(fn ->
      if previous_runner,
        do: Application.put_env(:codex_wrapper, :runner, previous_runner),
        else: Application.delete_env(:codex_wrapper, :runner)

      Application.delete_env(:codex_wrapper, :capture_parent)
    end)

    assert [] =
             CodexWrapper.stream("hello", idle_timeout_ms: 200, timeout: 5_000) |> Enum.to_list()

    assert_receive {:stream_opts, opts, 5_000}
    assert opts[:idle_timeout_ms] == 200
  end
end
