defmodule CodexWrapper.Structured do
  @moduledoc """
  Run a command with a JSON Schema and decode the final agent message.

  `run/4` takes a schema as a map, owns the temporary `--output-schema`
  file for the life of the process, runs the command with `--json`, and
  decodes the final agent message. `decode/2` does the decoding step for a
  `%CodexWrapper.Result{}` the caller already holds, for example from a run
  that set an explicit schema path. The explicit-path setters
  (`Exec.output_schema/2` and friends) are unchanged.

      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"],
        "additionalProperties" => false
      }

      {:ok, %{"name" => name}, %{result: _result, events: _events}} =
        CodexWrapper.Exec.new("Extract the name from: Hi, I'm Ada Lovelace.")
        |> CodexWrapper.Structured.run(schema, CodexWrapper.Config.new())

  ## Schema enforcement

  The schema is enforced by codex (`--output-schema`). This module does not
  re-validate the decoded value against it. It checks only that the final
  message is a JSON object or array; the optional `:parse` function is the
  caller-side check that the value has the expected domain shape.

  ## Final message selection

  The decoded message is the last completed `agent_message` item after the
  last `turn.started` event. Every parsed event is returned alongside, so
  earlier messages remain available. The turn outcome is the last
  `turn.completed` or `turn.failed` event. A top-level `error` event fails
  the run only when no terminal turn event follows it.

  ## Outcomes

  Success is `{:ok, value, detail}` where `detail` is
  `%{result: Result.t(), events: [JsonLineEvent.t()], text: String.t()}`.

  Failures after the process ran carry the same `detail` map (plus the
  fields noted) so the native output is never lost:

    * `{:turn_failed, detail}` -- the turn failed; `detail.error` is the
      native error object or message
    * `{:process_failed, detail}` -- codex exited non-zero, including after
      a `turn.completed`
    * `{:no_terminal, detail}` -- no `turn.completed` was emitted
    * `{:no_structured_output, detail}` -- no final agent message, or its
      text was empty or `null`
    * `{:invalid_json, detail}` -- the final message was not JSON;
      `detail.reason` is the `Jason.DecodeError`
    * `{:invalid_structured_output, detail}` -- the decoded value was not a
      JSON object or array
    * `{:parse_failed, reason, detail}` -- `:parse` returned
      `{:error, reason}`
    * `{:invalid_parse_result, value, detail}` -- `:parse` returned neither
      `{:ok, _}` nor `{:error, _}`

  Failures before spawning are `{:schema_encode, reason}` and
  `{:schema_file, reason}`. Runner errors such as `{:timeout, ms}` and
  `{:unsupported, capability}` are returned unchanged.
  """

  alias CodexWrapper.{Config, Exec, ExecFork, ExecResume, JsonLineEvent, Result, Review}

  @type command :: Exec.t() | ExecResume.t() | ExecFork.t() | Review.t()

  @type detail :: %{
          required(:result) => Result.t(),
          required(:events) => [JsonLineEvent.t()],
          optional(atom()) => term()
        }

  @type error ::
          {:turn_failed, detail()}
          | {:process_failed, detail()}
          | {:no_terminal, detail()}
          | {:no_structured_output, detail()}
          | {:invalid_json, detail()}
          | {:invalid_structured_output, detail()}
          | {:parse_failed, term(), detail()}
          | {:invalid_parse_result, term(), detail()}
          | {:schema_encode, term()}
          | {:schema_file, term()}
          | term()

  @doc """
  Run `command` with `schema` and decode its final agent message.

  Options:

    * `:parse` -- a 1-arity function mapping the decoded value to
      `{:ok, value}` or `{:error, reason}`. Defaults to returning the value.

  Any other options are passed to the command's `execute/3`, so observed
  execution options work as they do there.

  The schema file is created with mode `0600` in `System.tmp_dir!/0` and
  removed after the process exits, whether it succeeded, failed or raised.
  """
  @spec run(command(), map() | list(), Config.t(), keyword()) ::
          {:ok, term(), detail()} | {:error, error()}
  def run(command, schema, %Config{} = config, opts \\ [])
      when (is_map(schema) or is_list(schema)) and is_list(opts) do
    {decode_opts, execute_opts} = Keyword.split(opts, [:parse])
    module = command_module(command)

    with {:ok, json} <- encode_schema(schema) do
      with_schema_file(json, fn path ->
        command
        |> module.output_schema(path)
        |> Map.put(:json, true)
        |> module.execute(config, execute_opts)
      end)
      |> case do
        {:ok, %Result{} = result} -> decode(result, decode_opts)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Decode the final agent message of a `--json` run the caller already made.

  Accepts the same `:parse` option as `run/4` and returns the same outcomes.
  It never starts a process.
  """
  @spec decode(Result.t(), keyword()) :: {:ok, term(), detail()} | {:error, error()}
  def decode(%Result{} = result, opts \\ []) do
    events = JsonLineEvent.parse_lines(result.stdout)
    detail = %{result: result, events: events}

    with :ok <- check_turn(events, result, detail),
         {:ok, text} <- final_message(events, detail),
         detail = Map.put(detail, :text, text),
         {:ok, value} <- decode_json(text, detail),
         {:ok, parsed} <- parse(Keyword.get(opts, :parse), value, detail) do
      {:ok, parsed, detail}
    end
  end

  defp command_module(%Exec{}), do: Exec
  defp command_module(%ExecResume{}), do: ExecResume
  defp command_module(%ExecFork{}), do: ExecFork
  defp command_module(%Review{}), do: Review

  defp encode_schema(schema) do
    case Jason.encode(schema) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:schema_encode, reason}}
    end
  end

  defp with_schema_file(json, fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-wrapper-schema-#{System.pid()}-#{System.unique_integer([:positive])}.json"
      )

    with :ok <- File.write(path, json, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      try do
        fun.(path)
      after
        File.rm(path)
      end
    else
      {:error, reason} ->
        File.rm(path)
        {:error, {:schema_file, reason}}
    end
  end

  defp check_turn(events, result, detail) do
    case terminal(events) do
      %JsonLineEvent{event_type: "turn.failed", data: data} ->
        {:error, {:turn_failed, Map.put(detail, :error, data["error"])}}

      %JsonLineEvent{event_type: "turn.completed"} when result.exit_code != 0 ->
        {:error, {:process_failed, detail}}

      %JsonLineEvent{event_type: "turn.completed"} ->
        :ok

      nil ->
        no_terminal(events, result, detail)
    end
  end

  defp no_terminal(events, result, detail) do
    case Enum.filter(events, &(&1.event_type == "error")) do
      [] when result.exit_code != 0 -> {:error, {:process_failed, detail}}
      [] -> {:error, {:no_terminal, detail}}
      errors -> {:error, {:turn_failed, Map.put(detail, :error, List.last(errors).data)}}
    end
  end

  defp terminal(events) do
    events
    |> Enum.filter(&(&1.event_type in ["turn.completed", "turn.failed"]))
    |> List.last()
  end

  defp final_message(events, detail) do
    events
    |> final_turn()
    |> Enum.filter(&agent_message?/1)
    |> List.last()
    |> case do
      %JsonLineEvent{data: %{"item" => %{"text" => text}}} when is_binary(text) and text != "" ->
        {:ok, text}

      _ ->
        {:error, {:no_structured_output, detail}}
    end
  end

  defp final_turn(events) do
    case Enum.find_index(Enum.reverse(events), &(&1.event_type == "turn.started")) do
      nil -> events
      index -> Enum.take(events, -index)
    end
  end

  defp agent_message?(%JsonLineEvent{event_type: "item.completed", data: data}),
    do: match?(%{"item" => %{"type" => "agent_message"}}, data)

  defp agent_message?(_event), do: false

  defp decode_json(text, detail) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) or is_list(value) -> {:ok, value}
      {:ok, nil} -> {:error, {:no_structured_output, detail}}
      {:ok, _value} -> {:error, {:invalid_structured_output, detail}}
      {:error, reason} -> {:error, {:invalid_json, Map.put(detail, :reason, reason)}}
    end
  end

  defp parse(nil, value, _detail), do: {:ok, value}

  defp parse(fun, value, detail) when is_function(fun, 1) do
    case fun.(value) do
      {:ok, _parsed} = ok -> ok
      {:error, reason} -> {:error, {:parse_failed, reason, detail}}
      other -> {:error, {:invalid_parse_result, other, detail}}
    end
  end
end
