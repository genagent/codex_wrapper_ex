defmodule CodexWrapper.IntegrationTest do
  @moduledoc """
  Integration tests that run against the installed, authenticated Codex CLI.

  Run with:

      mix test --include integration
      mix test --only integration
  """

  use ExUnit.Case, async: false

  alias CodexWrapper.Commands.Features
  alias CodexWrapper.{Config, Exec, JsonLineEvent, Session}

  @moduletag :integration

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "codex_wrapper_integration_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, config: Config.new(working_dir: tmp_dir, timeout: 120_000)}
  end

  describe "live JSON contract" do
    test "emits the documented event sequence and a usable thread id", %{config: config} do
      assert {:ok, events} =
               "Reply with exactly: CODEX_WRAPPER_JSON_OK"
               |> live_exec()
               |> Exec.execute_json(config)

      assert_event_contract(events)

      thread_id = thread_id(events)
      assert is_binary(thread_id)
      assert thread_id != ""
      assert Session.extract_session_id(events) == thread_id

      assert Enum.any?(events, fn event ->
               JsonLineEvent.type?(event, "item.completed") and
                 get_in(JsonLineEvent.data(event), ["item", "type"]) == "agent_message"
             end)
    end
  end

  describe "live Port streaming" do
    test "streams the same NDJSON event contract", %{config: config} do
      events =
        "Reply with exactly: CODEX_WRAPPER_STREAM_OK"
        |> live_exec()
        |> Exec.stream(config)
        |> Enum.to_list()

      assert_event_contract(events)
      assert is_binary(thread_id(events))
    end
  end

  describe "live feature list" do
    test "retains the CLI's name, stage, and boolean-state rows", %{config: config} do
      assert {:ok, output} = Features.list(config)

      rows =
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&Regex.match?(feature_row_pattern(), &1))

      assert rows != []
    end
  end

  defp live_exec(prompt) do
    prompt
    |> Exec.new()
    |> Exec.sandbox(:read_only)
    |> Exec.skip_git_repo_check()
    |> Exec.ephemeral()
    |> Exec.ignore_user_config()
  end

  defp assert_event_contract(events) do
    event_types = Enum.map(events, &JsonLineEvent.event_type/1)

    assert event_types != []

    assert_in_order(event_types, [
      "thread.started",
      "turn.started",
      "item.completed",
      "turn.completed"
    ])

    assert Enum.all?(events, fn event ->
             is_map(JsonLineEvent.data(event)) and is_binary(event.raw)
           end)
  end

  defp assert_in_order(actual, expected) do
    Enum.reduce(expected, actual, fn expected_type, remaining ->
      case Enum.split_while(remaining, &(&1 != expected_type)) do
        {_before, [^expected_type | rest]} ->
          rest

        {_before, []} ->
          flunk("missing #{inspect(expected_type)} after #{inspect(actual)}")
      end
    end)

    :ok
  end

  defp thread_id(events) do
    events
    |> Enum.find(&JsonLineEvent.type?(&1, "thread.started"))
    |> JsonLineEvent.get("thread_id")
  end

  defp feature_row_pattern do
    ~r/^\S+\s+(?:stable|experimental|under development|deprecated|removed)\s+(?:true|false)$/
  end
end
