defmodule CodexWrapper.JsonLineEvent do
  @moduledoc """
  A single event from codex's `--json` NDJSON output.

  When using `--json`, the codex CLI emits one JSON object per line.
  Each event has an event type and associated data.

  ## Event types

  Common event types include:
  - `"thread.started"` -- thread initialization
  - `"turn.started"` -- turn began
  - `"item.completed"` -- item completed
  - `"turn.completed"` -- turn finished
  """

  @type t :: %__MODULE__{
          event_type: String.t() | nil,
          data: map(),
          raw: String.t()
        }

  defstruct [:event_type, :raw, data: %{}]

  @doc """
  Parse a single NDJSON line into a `%JsonLineEvent{}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, data} when is_map(data) ->
        {:ok,
         %__MODULE__{
           event_type: data["type"],
           data: data,
           raw: line
         }}

      {:ok, _other} ->
        {:error, :not_an_object}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  @doc """
  Parse multiple NDJSON lines from stdout into a list of events.

  Filters for lines that look like JSON objects and silently drops
  lines that fail to parse.
  """
  @spec parse_lines(String.t()) :: [t()]
  def parse_lines(stdout) when is_binary(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(String.trim_leading(&1), "{"))
    |> Enum.flat_map(fn line ->
      case parse(line) do
        {:ok, event} -> [event]
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Return the event type string.
  """
  @spec event_type(t()) :: String.t() | nil
  def event_type(%__MODULE__{event_type: type}), do: type

  @doc """
  Return the full data map.
  """
  @spec data(t()) :: map()
  def data(%__MODULE__{data: data}), do: data

  @doc """
  Get a value from the data map by key.
  """
  @spec get(t(), String.t(), term()) :: term()
  def get(%__MODULE__{data: data}, key, default \\ nil), do: Map.get(data, key, default)

  @doc """
  Whether this event matches the given type.
  """
  @spec type?(t(), String.t()) :: boolean()
  def type?(%__MODULE__{event_type: type}, expected), do: type == expected
end
