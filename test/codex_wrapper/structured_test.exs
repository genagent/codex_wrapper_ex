defmodule CodexWrapper.StructuredTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, Exec, ExecResume, JsonLineEvent, Result, Review, Structured}

  @fake Path.expand("../fixtures/fake_codex_structured", __DIR__)

  @schema %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"],
    "additionalProperties" => false
  }

  defmodule Person do
    defstruct [:name]
  end

  # Run a command against the fake executable. Returns the outcome and the
  # recorded invocations as {argv, schema_seen} pairs.
  defp run_fake(scenario, opts \\ [], command \\ Exec.new("extract")) do
    calls =
      Path.join(
        System.tmp_dir!(),
        "codex-structured-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(calls) end)

    config =
      Config.new(
        binary: @fake,
        timeout: 10_000,
        env: [{"FAKE_CODEX_SCENARIO", scenario}, {"FAKE_CODEX_CALLS", calls}]
      )

    outcome = Structured.run(command, @schema, config, opts)

    invocations =
      if File.exists?(calls) do
        calls
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.chunk_every(2)
        |> Enum.map(fn [argv, "schema:" <> schema] -> {argv, schema} end)
      else
        []
      end

    {outcome, invocations}
  end

  defp schema_path(argv) do
    [_, path] = Regex.run(~r/--output-schema (\S+)/, argv)
    path
  end

  describe "run/4 (fake executable)" do
    test "decodes an object and removes the schema file after the run" do
      assert {{:ok, %{"name" => "Ada Lovelace"}, detail}, [{argv, schema}]} = run_fake("object")

      assert argv =~ "--json"
      assert Jason.decode!(schema) == @schema
      refute File.exists?(schema_path(argv))
      assert %Result{exit_code: 0} = detail.result
      assert [%JsonLineEvent{event_type: "thread.started"} | _] = detail.events
      assert detail.text == ~s({"name":"Ada Lovelace"})
    end

    test "decodes an array" do
      assert {{:ok, [%{"name" => "Ada"}, %{"name" => "Grace"}], _}, [_]} = run_fake("array")
    end

    test "maps the value through :parse" do
      parse = fn %{"name" => name} -> {:ok, %Person{name: name}} end
      assert {{:ok, %Person{name: "Ada Lovelace"}, _}, [_]} = run_fake("object", parse: parse)
    end

    test "selects the last agent message and keeps every event" do
      assert {{:ok, %{"name" => "final"}, detail}, [_]} = run_fake("multiple_messages")

      texts =
        for %JsonLineEvent{event_type: "item.completed", data: %{"item" => item}} <-
              detail.events,
            do: item["text"]

      assert texts == [~s({"name":"draft"}), "thinking", ~s({"name":"final"})]
    end

    test "an error event followed by turn.completed does not fail the run" do
      assert {{:ok, %{"name" => "Ada"}, _}, [_]} = run_fake("transient_error")
    end

    test "missing and null messages are :no_structured_output" do
      for scenario <- ["missing", "null"] do
        assert {{:error, {:no_structured_output, %{result: %Result{}}}}, [_]} =
                 run_fake(scenario)
      end
    end

    test "a non-JSON message is :invalid_json with the text and events" do
      assert {{:error, {:invalid_json, detail}}, [_]} = run_fake("invalid_json")
      assert %Jason.DecodeError{} = detail.reason
      assert detail.text == ~s({"name":)
    end

    test "a scalar message is :invalid_structured_output" do
      assert {{:error, {:invalid_structured_output, _}}, [_]} = run_fake("scalar")
    end

    test "turn.failed is never decoded, even with a partial message" do
      assert {{:error, {:turn_failed, detail}}, [_]} = run_fake("turn_failed")
      assert detail.error == %{"message" => "synthetic failure"}
    end

    test "an error event with no terminal turn is :turn_failed" do
      assert {{:error, {:turn_failed, %{error: %{"message" => "synthetic stream error"}}}}, [_]} =
               run_fake("error_only")
    end

    test "output without a terminal turn is :no_terminal" do
      assert {{:error, {:no_terminal, _}}, [_]} = run_fake("no_terminal")
    end

    test "a non-zero exit after turn.completed is :process_failed" do
      assert {{:error, {:process_failed, %{result: %Result{exit_code: 1}}}}, [_]} =
               run_fake("success_then_exit")
    end

    test "a crash without events is :process_failed" do
      assert {{:error, {:process_failed, %{result: %Result{exit_code: 2}}}}, [_]} =
               run_fake("crash")
    end

    test "a wrong domain shape is :parse_failed" do
      parse = fn
        %{"name" => _} = value -> {:ok, value}
        other -> {:error, {:unexpected_shape, other}}
      end

      assert {{:error, {:parse_failed, {:unexpected_shape, [_ | _]}, _}}, [_]} =
               run_fake("array", parse: parse)
    end

    test "a parser returning a bare value is :invalid_parse_result" do
      assert {{:error, {:invalid_parse_result, :bare, _}}, [_]} =
               run_fake("object", parse: fn _ -> :bare end)
    end

    test "works for resume and review commands" do
      resume = ExecResume.new() |> ExecResume.last() |> ExecResume.prompt("again")
      assert {{:ok, %{"name" => _}, _}, [{argv, _}]} = run_fake("object", [], resume)
      assert argv =~ "resume"

      assert {{:ok, %{"name" => _}, _}, [{argv, _}]} = run_fake("object", [], Review.new())
      assert argv =~ "review"
    end
  end

  describe "run/4 before spawning" do
    test "an unencodable schema is rejected without starting a process" do
      config = Config.new(binary: "/nonexistent/codex")

      assert {:error, {:schema_encode, _}} =
               Structured.run(Exec.new("x"), %{"bad" => {:tuple}}, config)
    end
  end

  describe "decode/2" do
    test "decodes a result the caller already holds" do
      stdout =
        Enum.map_join(
          [
            %{"type" => "turn.started"},
            %{
              "type" => "item.completed",
              "item" => %{"type" => "agent_message", "text" => ~s({"name":"Ada"})}
            },
            %{"type" => "turn.completed"}
          ],
          "\n",
          &Jason.encode!/1
        )

      result = Result.from_cmd({stdout, 0})
      assert {:ok, %{"name" => "Ada"}, %{result: ^result}} = Structured.decode(result)
    end
  end
end
