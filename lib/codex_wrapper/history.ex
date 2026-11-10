defmodule CodexWrapper.History.SessionSummary do
  @moduledoc """
  Summary of one rollout file, taken from its name and `File.stat/1`.

  See `CodexWrapper.History.list_sessions/2`. The file is not opened, so
  the summary carries no content fields; read the session for those.

  `started_at` is the timestamp codex puts in the file name
  (`rollout-<YYYY-MM-DDTHH-MM-SS>-<id>`), in local time with no zone, so it
  is a `NaiveDateTime`.
  """

  @enforce_keys [:id, :path, :archived?, :compressed?, :size_bytes]
  defstruct [:id, :path, :started_at, :archived?, :compressed?, :size_bytes, :modified_at]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          started_at: NaiveDateTime.t() | nil,
          archived?: boolean(),
          compressed?: boolean(),
          size_bytes: non_neg_integer(),
          modified_at: DateTime.t() | nil
        }
end

defmodule CodexWrapper.History.SessionLog do
  @moduledoc """
  One session read by `CodexWrapper.History.read_session/2`.

  `entries` is a lazy stream of `t:CodexWrapper.History.entry/0`. Each
  enumeration reopens the file, so it can be enumerated more than once,
  and a stream that is never enumerated never opens it. `meta` is the
  payload of the leading `session_meta` entry, or `nil` when the file does
  not start with one.
  """

  @enforce_keys [:id, :path, :entries]
  defstruct [:id, :path, :meta, :entries]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          meta: map() | nil,
          entries: Enumerable.t()
        }
end

defmodule CodexWrapper.History do
  @moduledoc """
  Read-side access to codex's persisted session rollouts.

  Codex writes each persisted session to a rollout file of JSON lines under
  `$CODEX_HOME` (default `~/.codex`):

    * `sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl`
    * `sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl.zst`
    * `archived_sessions/rollout-<timestamp>-<id>.jsonl` and `.jsonl.zst`

  Codex compresses rollouts with zstd and moves them when they are
  archived, so a session's path can change between a listing and a read.
  `find_session/2` and `read_session/2` resolve the id when they are
  called.

  This module only reads. Archive, unarchive and delete go through the CLI
  with `CodexWrapper.Commands.Archive`. It covers rollout files only, not
  `session_index.jsonl`, `thread_history_1.sqlite` or the app-server's
  paginated thread view.

  ## Entries

  Each line is decoded on its own. Lines with codex's envelope
  (`timestamp`, `type`, `payload`, and `ordinal` in newer files) become
  `%{timestamp: ..., type: ..., payload: ..., ordinal: ...}` with the
  payload left as decoded JSON. Unknown types pass through unchanged.
  Lines without the envelope, from older files, come back with
  `type: nil` and the whole decoded line as `payload`. Malformed lines are
  skipped.

  ## Large and compressed files

  Rollouts can be hundreds of megabytes. `read_session/2` returns entries
  as a lazy stream: plain files are read line by line, and `.jsonl.zst`
  files are decompressed in chunks through a `:zstd` context, so memory
  use stays bounded by the longest line.

  `:zstd` ships with OTP 28 and later. On OTP 27, reading a compressed
  rollout returns `{:error, {:unsupported, :zstd}}`; plain rollouts still
  read, and `list_sessions/2` lists both.

  ## Usage

      {:ok, history} = CodexWrapper.History.home()

      {:ok, sessions} =
        CodexWrapper.History.list_sessions(history, archived: :all, limit: 20)

      {:ok, log} = CodexWrapper.History.read_session(history, hd(sessions).id)
      log.meta["cwd"]
      Enum.take(log.entries, 5)
  """

  alias CodexWrapper.History.{SessionLog, SessionSummary}

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @typedoc """
  One rollout line. `type` is `nil` for a line without codex's envelope;
  `payload` is then the whole decoded line.
  """
  @type entry :: %{
          timestamp: String.t() | nil,
          type: String.t() | nil,
          payload: term(),
          ordinal: integer() | nil
        }

  @type list_opt ::
          {:archived, boolean() | :all}
          | {:after, NaiveDateTime.t()}
          | {:before, NaiveDateTime.t()}
          | {:limit, pos_integer()}
          | {:sort, :recency_desc | :recency_asc}

  @chunk_bytes 65_536
  @meta_scan 8
  @name ~r/^rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-(.+)\.jsonl(\.zst)?$/

  @doc """
  The history under `$CODEX_HOME`, or `~/.codex` when it is unset or empty.

  Returns `{:error, :no_home}` when neither can be determined. The
  directory does not have to exist; listing a missing tree returns `[]`.
  """
  @spec home() :: {:ok, t()} | {:error, :no_home}
  def home do
    case System.get_env("CODEX_HOME") do
      home when is_binary(home) and home != "" ->
        {:ok, at(home)}

      _ ->
        case System.user_home() do
          nil -> {:error, :no_home}
          user_home -> {:ok, at(Path.join(user_home, ".codex"))}
        end
    end
  end

  @doc "The history rooted at `path`, a codex home directory."
  @spec at(Path.t()) :: t()
  def at(path) when is_binary(path), do: %__MODULE__{root: Path.expand(path)}

  @doc "The history's root directory."
  @spec root(t()) :: String.t()
  def root(%__MODULE__{root: root}), do: root

  @doc """
  List rollout files, newest first by default.

  ## Options

    * `:archived` - `false` (default) lists `sessions/` only, `true` lists
      `archived_sessions/` only, `:all` lists both.
    * `:after` / `:before` - keep sessions whose `started_at` is strictly
      after or before this `NaiveDateTime`.
    * `:limit` - keep at most this many, after sorting.
    * `:sort` - `:recency_desc` (default) or `:recency_asc`, by
      `started_at`, then id.

  A session present as both `.jsonl` and `.jsonl.zst` is listed once,
  preferring the plain file.
  """
  @spec list_sessions(t(), [list_opt()]) :: {:ok, [SessionSummary.t()]}
  def list_sessions(%__MODULE__{} = history, opts \\ []) do
    archived = Keyword.get(opts, :archived, false)

    unless archived in [true, false, :all] do
      raise ArgumentError, ":archived must be true, false or :all, got: #{inspect(archived)}"
    end

    sessions =
      history
      |> rollout_paths(archived)
      |> Enum.flat_map(&summary/1)
      |> dedupe()
      |> filter_time(Keyword.get(opts, :after), &(NaiveDateTime.compare(&1, &2) == :gt))
      |> filter_time(Keyword.get(opts, :before), &(NaiveDateTime.compare(&1, &2) == :lt))
      |> sort(Keyword.get(opts, :sort, :recency_desc))
      |> limit(Keyword.get(opts, :limit))

    {:ok, sessions}
  end

  @doc """
  Find the rollout file for a session id, active or archived.

  Returns `{:error, :not_found}` when no file matches.
  """
  @spec find_session(t(), String.t()) :: {:ok, SessionSummary.t()} | {:error, :not_found}
  def find_session(%__MODULE__{} = history, id) when is_binary(id) do
    if valid_id?(id) do
      history
      |> rollout_paths(:all, "rollout-*-#{id}.jsonl*")
      |> Enum.flat_map(&summary/1)
      |> Enum.filter(&(&1.id == id))
      |> dedupe()
      |> case do
        [] -> {:error, :not_found}
        [summary | _] -> {:ok, summary}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Read a session by id.

  Resolves the id with `find_session/2` and reads the leading
  `session_meta` entry. `entries` stays lazy; see
  `CodexWrapper.History.SessionLog`. If the file moves between the lookup
  and the read, the lookup runs once more.

  Returns `{:error, :not_found}`, `{:error, {:unsupported, :zstd}}` for a
  compressed rollout on OTP 27, or `{:error, {:read, reason}}`.
  """
  @spec read_session(t(), String.t()) ::
          {:ok, SessionLog.t()} | {:error, :not_found | {:unsupported, :zstd} | {:read, term()}}
  def read_session(%__MODULE__{} = history, id) when is_binary(id) do
    with {:ok, summary} <- find_session(history, id),
         {:error, {:read, :enoent}} <- read_summary(summary),
         {:ok, summary} <- find_session(history, id) do
      read_summary(summary)
    end
  end

  @doc """
  Stream the entries of one rollout file by path.

  Raises `File.Error` when enumeration cannot open the file, and
  `ArgumentError` for a `.zst` file when `:zstd` is unavailable.
  """
  @spec stream_entries(Path.t()) :: Enumerable.t()
  def stream_entries(path) when is_binary(path) do
    path
    |> stream_lines()
    |> Stream.flat_map(&decode_line/1)
  end

  # --- Reading ---

  defp read_summary(%SessionSummary{compressed?: true} = summary) do
    if zstd?(), do: read_file(summary), else: {:error, {:unsupported, :zstd}}
  end

  defp read_summary(summary), do: read_file(summary)

  defp read_file(%SessionSummary{id: id, path: path}) do
    entries = stream_entries(path)

    meta =
      entries
      |> Enum.take(@meta_scan)
      |> Enum.find_value(fn
        %{type: "session_meta", payload: payload} -> payload
        _ -> nil
      end)

    {:ok, %SessionLog{id: id, path: path, meta: meta, entries: entries}}
  rescue
    error in File.Error -> {:error, {:read, error.reason}}
  end

  defp stream_lines(path) do
    if String.ends_with?(path, ".zst") do
      zstd_lines(path)
    else
      File.stream!(path, :line)
    end
  end

  defp zstd_lines(path) do
    unless zstd?() do
      raise ArgumentError, "reading #{path} needs :zstd, which ships with OTP 28 and later"
    end

    Stream.resource(
      fn -> open_zstd(path) end,
      &next_chunk/1,
      &close_zstd/1
    )
  end

  defp open_zstd(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        {:ok, context} = zstd().context(:decompress)
        {io, context, ""}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open", path: path
    end
  end

  defp next_chunk({:done, _context} = state), do: {:halt, state}

  defp next_chunk({io, context, carry}) do
    case IO.binread(io, @chunk_bytes) do
      data when is_binary(data) ->
        output = decompress(context, data)
        {lines, carry} = split_lines(carry <> output)
        {lines, {io, context, carry}}

      :eof ->
        {:done, output} = zstd().finish(context, "")
        rest = carry <> IO.iodata_to_binary(output)
        File.close(io)
        {if(rest == "", do: [], else: String.split(rest, "\n", trim: true)), {:done, context}}
    end
  end

  defp decompress(context, data) do
    case zstd().stream(context, data) do
      {:continue, output} ->
        IO.iodata_to_binary(output)

      {:continue, remainder, output} ->
        IO.iodata_to_binary(output) <> decompress(context, remainder)
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp close_zstd({:done, context}), do: zstd().close(context)

  defp close_zstd({io, context, _carry}) do
    File.close(io)
    zstd().close(context)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type, "payload" => payload} = decoded} when is_binary(type) ->
        [
          %{
            timestamp: decoded["timestamp"],
            type: type,
            payload: payload,
            ordinal: decoded["ordinal"]
          }
        ]

      {:ok, decoded} ->
        timestamp = if is_map(decoded), do: decoded["timestamp"]
        [%{timestamp: timestamp, type: nil, payload: decoded, ordinal: nil}]

      {:error, _} ->
        []
    end
  end

  defp zstd?, do: Code.ensure_loaded?(:zstd)

  # Resolved at run time: :zstd exists only on OTP 28 and later, and naming
  # it in a remote call makes the compiler and dialyzer report it as
  # undefined on OTP 27. Only called after zstd?/0 returned true.
  defp zstd, do: String.to_existing_atom("zstd")

  # --- Listing ---

  defp rollout_paths(history, archived, pattern \\ "rollout-*.jsonl*") do
    active = Path.join([history.root, "sessions", "*", "*", "*", pattern])
    archive = Path.join([history.root, "archived_sessions", pattern])

    case archived do
      false -> Path.wildcard(active)
      true -> Path.wildcard(archive)
      :all -> Path.wildcard(active) ++ Path.wildcard(archive)
    end
  end

  defp summary(path) do
    with {:ok, stamp, id, zst} <- parse_name(Path.basename(path)),
         {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
           File.stat(path, time: :posix) do
      [
        %SessionSummary{
          id: id,
          path: path,
          started_at: started_at(stamp),
          archived?: Path.basename(Path.dirname(path)) == "archived_sessions",
          compressed?: zst != "",
          size_bytes: size,
          modified_at: DateTime.from_unix!(mtime)
        }
      ]
    else
      _ -> []
    end
  end

  defp parse_name(name) do
    case Regex.run(@name, name) do
      [_, stamp, id] -> {:ok, stamp, id, ""}
      [_, stamp, id, zst] -> {:ok, stamp, id, zst}
      nil -> :error
    end
  end

  defp started_at(
         <<date::binary-size(10), "T", h::binary-size(2), "-", m::binary-size(2), "-",
           s::binary-size(2)>>
       ) do
    case NaiveDateTime.from_iso8601("#{date}T#{h}:#{m}:#{s}") do
      {:ok, time} -> time
      {:error, _} -> nil
    end
  end

  # One entry per id and location: a plain file sorts before its .zst twin.
  defp dedupe(summaries) do
    summaries
    |> Enum.sort_by(&{&1.id, &1.archived?, &1.compressed?})
    |> Enum.uniq_by(&{&1.id, &1.archived?})
  end

  defp filter_time(summaries, nil, _keep?), do: summaries

  defp filter_time(summaries, %NaiveDateTime{} = bound, keep?) do
    Enum.filter(summaries, &(&1.started_at && keep?.(&1.started_at, bound)))
  end

  defp filter_time(_summaries, bound, _keep?),
    do: raise(ArgumentError, ":after and :before take a NaiveDateTime, got: #{inspect(bound)}")

  defp sort(summaries, :recency_desc),
    do: Enum.sort_by(summaries, &sort_key/1, :desc)

  defp sort(summaries, :recency_asc), do: Enum.sort_by(summaries, &sort_key/1, :asc)

  defp sort(_summaries, other),
    do:
      raise(ArgumentError, ":sort must be :recency_desc or :recency_asc, got: #{inspect(other)}")

  defp sort_key(%SessionSummary{started_at: nil, id: id}), do: {0, "", id}

  defp sort_key(%SessionSummary{started_at: time, id: id}),
    do: {1, NaiveDateTime.to_iso8601(time), id}

  defp limit(summaries, nil), do: summaries

  defp limit(summaries, n) when is_integer(n) and n > 0, do: Enum.take(summaries, n)

  defp limit(_summaries, n),
    do: raise(ArgumentError, ":limit must be a positive integer, got: #{inspect(n)}")

  # Ids are matched inside a wildcard, so refuse glob characters and paths.
  defp valid_id?(id), do: id != "" and not String.contains?(id, ["/", "*", "?", "[", "{", "\\"])
end
