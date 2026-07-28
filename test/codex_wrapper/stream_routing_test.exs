defmodule CodexWrapper.StreamRoutingTest do
  @moduledoc """
  The four `stream/*` call sites go through `CodexWrapper.Runner`.

  A scripted runner stands in for the CLI, so what each builder hands the
  runner (binary, argv, opts, timeout) is observable without the real
  binary, the way `binary: "echo"` makes the execute paths observable.
  """

  # Not async: these override the :runner application env.
  use ExUnit.Case, async: false

  alias CodexWrapper.{Config, Exec, ExecResume, JsonLineEvent, Review, Session}

  defmodule ScriptedRunner do
    @moduledoc false
    @behaviour CodexWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}

    @impl true
    def stream_lines(binary, args, opts, timeout) do
      {pid, lines} = Application.fetch_env!(:codex_wrapper, :scripted_runner)
      send(pid, {:stream_lines, binary, args, opts, timeout})

      # Reporting each pull makes the laziness of the parse pipeline
      # observable: a halted consumer should not drain the runner.
      Stream.each(lines, fn line -> send(pid, {:pulled, line}) end)
    end
  end

  setup context do
    lines = Map.get(context, :lines, [~s({"type":"thread.started","thread_id":"t-1"})])

    Application.put_env(:codex_wrapper, :runner, ScriptedRunner)
    Application.put_env(:codex_wrapper, :scripted_runner, {self(), lines})

    on_exit(fn ->
      Application.delete_env(:codex_wrapper, :runner)
      Application.delete_env(:codex_wrapper, :scripted_runner)
    end)

    :ok
  end

  defp config(opts \\ []), do: Config.new(Keyword.merge([binary: "codex"], opts))

  describe "Exec.stream/2" do
    test "routes through the runner with --json forced" do
      events = "hello" |> Exec.new() |> Exec.stream(config()) |> Enum.to_list()

      assert_received {:stream_lines, "codex", args, _opts, _timeout}
      assert "exec" in args
      assert "--json" in args
      assert "hello" in args

      assert [%JsonLineEvent{event_type: "thread.started"}] = events
    end

    test "passes the config timeout and stream opts to the runner" do
      "hello" |> Exec.new() |> Exec.stream(config(timeout: 1_234)) |> Enum.to_list()

      assert_received {:stream_lines, "codex", _args, opts, 1_234}

      # Streaming parses NDJSON off stdout; merging stderr into it would
      # put unparseable lines in the stream.
      assert opts[:stderr_to_stdout] == false
    end

    test "honors the configured binary" do
      "hello" |> Exec.new() |> Exec.stream(config(binary: "/opt/codex")) |> Enum.to_list()

      assert_received {:stream_lines, "/opt/codex", _args, _opts, _timeout}
    end

    @tag lines: [
           ~s({"type":"thread.started"}),
           "not json at all",
           ~s({"type":"item.completed"})
         ]
    test "drops lines that do not parse as JSON" do
      events = "hello" |> Exec.new() |> Exec.stream(config()) |> Enum.to_list()

      assert ["thread.started", "item.completed"] = Enum.map(events, & &1.event_type)
    end

    @tag lines: [
           ~s({"type":"item.1"}),
           ~s({"type":"item.2"}),
           ~s({"type":"item.3"})
         ]
    test "stays lazy -- an early halt does not drain the runner" do
      events = "hello" |> Exec.new() |> Exec.stream(config()) |> Enum.take(1)

      assert [%JsonLineEvent{event_type: "item.1"}] = events

      assert_received {:pulled, ~s({"type":"item.1"})}
      refute_received {:pulled, ~s({"type":"item.3"})}
    end
  end

  describe "ExecResume.stream/2" do
    test "routes through the runner with --json forced" do
      events =
        ExecResume.new()
        |> ExecResume.session_id("sid-1")
        |> ExecResume.prompt("more")
        |> ExecResume.stream(config())
        |> Enum.to_list()

      assert_received {:stream_lines, "codex", args, opts, _timeout}
      assert ["exec", "resume" | _] = args
      assert "--json" in args
      assert opts[:stderr_to_stdout] == false

      assert [%JsonLineEvent{event_type: "thread.started"}] = events
    end
  end

  describe "Review.stream/2" do
    test "routes through the runner with --json forced" do
      events =
        Review.new()
        |> Review.uncommitted()
        |> Review.stream(config())
        |> Enum.to_list()

      # Before the Runner refactor this path opened the binary directly,
      # so it never got the stdin-closing wrapper the other two had.
      assert_received {:stream_lines, "codex", args, opts, _timeout}
      assert ["exec", "review" | _] = args
      assert "--json" in args
      assert opts[:stderr_to_stdout] == false

      assert [%JsonLineEvent{event_type: "thread.started"}] = events
    end
  end

  describe "Session.stream/3" do
    test "a session with no id streams through the exec path" do
      session = Session.new(config())

      assert {^session, stream} = Session.stream(session, "hello")
      assert [%JsonLineEvent{}] = Enum.to_list(stream)

      assert_received {:stream_lines, "codex", args, _opts, _timeout}
      assert ["exec" | rest] = args
      refute "resume" in rest
    end

    test "a session with an id streams through the resume path" do
      session = %{Session.new(config()) | session_id: "sid-1"}

      assert {^session, stream} = Session.stream(session, "more")
      assert [%JsonLineEvent{}] = Enum.to_list(stream)

      assert_received {:stream_lines, "codex", args, _opts, _timeout}
      assert ["exec", "resume" | _] = args
      assert "sid-1" in args
    end
  end
end
