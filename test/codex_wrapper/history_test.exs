defmodule CodexWrapper.HistoryTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.History
  alias CodexWrapper.History.{SessionLog, SessionSummary}

  @moduletag :tmp_dir

  @id_a "019b1e96-6935-7a02-a61e-325504b0b001"
  @id_b "019b1e96-6935-7a02-a61e-325504b0b002"
  @id_c "019b1e96-6935-7a02-a61e-325504b0b003"

  defp line(type, payload, extra \\ %{}) do
    Map.merge(
      %{"timestamp" => "2026-11-01T10:00:00.000Z", "type" => type, "payload" => payload},
      extra
    )
    |> Jason.encode!()
  end

  defp rollout(id) do
    [
      line("session_meta", %{"id" => id, "cwd" => "/repo", "cli_version" => "0.165.0"}, %{
        "ordinal" => 0
      }),
      line("event_msg", %{"type" => "user_message", "message" => "hi"}, %{"ordinal" => 1}),
      "not json",
      "",
      line("future_type", %{"anything" => true}),
      Jason.encode!(%{"record_type" => "legacy", "text" => "old"})
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp write(dir, relative, contents) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  describe "home/0 and at/1" do
    test "at/1 expands the root" do
      assert History.root(History.at("relative/dir")) == Path.expand("relative/dir")
    end
  end

  describe "list_sessions/2" do
    setup %{tmp_dir: dir} do
      write(dir, "sessions/2026/11/01/rollout-2026-11-01T09-00-00-#{@id_a}.jsonl", rollout(@id_a))
      write(dir, "sessions/2026/11/02/rollout-2026-11-02T09-00-00-#{@id_b}.jsonl", rollout(@id_b))
      write(dir, "archived_sessions/rollout-2026-10-01T09-00-00-#{@id_c}.jsonl", rollout(@id_c))
      write(dir, "sessions/2026/11/02/not-a-rollout.jsonl", "")
      write(dir, "session_index.jsonl", "")
      %{history: History.at(dir)}
    end

    test "lists active sessions newest first by default", %{history: history} do
      assert {:ok, [%SessionSummary{id: @id_b} = b, %SessionSummary{id: @id_a}]} =
               History.list_sessions(history)

      assert b.started_at == ~N[2026-11-02 09:00:00]
      refute b.archived?
      refute b.compressed?
      assert b.size_bytes == byte_size(rollout(@id_b))
      assert %DateTime{} = b.modified_at
    end

    test "archived: true lists archived only, :all lists both", %{history: history} do
      assert {:ok, [%SessionSummary{id: @id_c, archived?: true}]} =
               History.list_sessions(history, archived: true)

      assert {:ok, sessions} = History.list_sessions(history, archived: :all, sort: :recency_asc)
      assert Enum.map(sessions, & &1.id) == [@id_c, @id_a, @id_b]
    end

    test "filters by start time and limits", %{history: history} do
      assert {:ok, [%{id: @id_b}]} =
               History.list_sessions(history, after: ~N[2026-11-01 09:00:00])

      assert {:ok, [%{id: @id_a}]} =
               History.list_sessions(history, before: ~N[2026-11-02 09:00:00])

      assert {:ok, [%{id: @id_b}]} = History.list_sessions(history, limit: 1)
    end

    test "rejects invalid options", %{history: history} do
      assert_raise ArgumentError, fn -> History.list_sessions(history, archived: :maybe) end
      assert_raise ArgumentError, fn -> History.list_sessions(history, limit: 0) end
      assert_raise ArgumentError, fn -> History.list_sessions(history, sort: :size) end
      assert_raise ArgumentError, fn -> History.list_sessions(history, after: "2026-11-01") end
    end

    test "a missing home lists nothing", %{tmp_dir: dir} do
      assert {:ok, []} =
               History.list_sessions(History.at(Path.join(dir, "missing")), archived: :all)
    end
  end

  describe "read_session/2 on plain rollouts" do
    setup %{tmp_dir: dir} do
      write(dir, "sessions/2026/11/01/rollout-2026-11-01T09-00-00-#{@id_a}.jsonl", rollout(@id_a))
      write(dir, "archived_sessions/rollout-2026-10-01T09-00-00-#{@id_c}.jsonl", rollout(@id_c))
      %{history: History.at(dir)}
    end

    test "returns meta and decoded entries, skipping malformed lines", %{history: history} do
      assert {:ok, %SessionLog{id: @id_a, meta: meta, entries: entries}} =
               History.read_session(history, @id_a)

      assert meta == %{"id" => @id_a, "cwd" => "/repo", "cli_version" => "0.165.0"}

      assert [
               %{type: "session_meta", ordinal: 0, timestamp: "2026-11-01T10:00:00.000Z"},
               %{type: "event_msg", ordinal: 1, payload: %{"type" => "user_message"}},
               %{type: "future_type", ordinal: nil, payload: %{"anything" => true}},
               %{type: nil, payload: %{"record_type" => "legacy", "text" => "old"}}
             ] = Enum.to_list(entries)
    end

    test "entries can be enumerated more than once", %{history: history} do
      {:ok, log} = History.read_session(history, @id_a)
      assert Enum.count(log.entries) == Enum.count(log.entries)
    end

    test "finds archived sessions", %{history: history} do
      assert {:ok, %SessionSummary{archived?: true}} = History.find_session(history, @id_c)
      assert {:ok, %SessionLog{id: @id_c}} = History.read_session(history, @id_c)
    end

    test "an unknown or glob-shaped id is not found", %{history: history} do
      assert {:error, :not_found} = History.read_session(history, @id_b)
      assert {:error, :not_found} = History.find_session(history, "*")
      assert {:error, :not_found} = History.find_session(history, "../#{@id_a}")
    end

    test "a file without session_meta has nil meta", %{tmp_dir: dir, history: history} do
      write(
        dir,
        "sessions/2026/11/03/rollout-2026-11-03T09-00-00-#{@id_b}.jsonl",
        line("event_msg", %{}) <> "\n"
      )

      assert {:ok, %SessionLog{meta: nil}} = History.read_session(history, @id_b)
    end
  end

  if Code.ensure_loaded?(:zstd) do
    # :zstd exists on OTP 28 and later; resolved at run time for OTP 27 builds.
    defp compress(contents),
      do: IO.iodata_to_binary(String.to_existing_atom("zstd").compress(contents))

    describe "compressed rollouts" do
      setup %{tmp_dir: dir} do
        write(
          dir,
          "sessions/2026/11/01/rollout-2026-11-01T09-00-00-#{@id_a}.jsonl.zst",
          compress(rollout(@id_a))
        )

        write(
          dir,
          "archived_sessions/rollout-2026-10-01T09-00-00-#{@id_c}.jsonl.zst",
          compress(rollout(@id_c))
        )

        %{history: History.at(dir)}
      end

      test "are listed and read like plain ones", %{history: history} do
        assert {:ok, [%SessionSummary{id: @id_a, compressed?: true}]} =
                 History.list_sessions(history)

        assert {:ok, %SessionLog{meta: %{"id" => @id_c}, entries: entries}} =
                 History.read_session(history, @id_c)

        assert Enum.map(entries, & &1.type) == ["session_meta", "event_msg", "future_type", nil]
      end

      test "a session in both forms is listed once, preferring the plain file", %{
        tmp_dir: dir,
        history: history
      } do
        plain =
          write(
            dir,
            "sessions/2026/11/01/rollout-2026-11-01T09-00-00-#{@id_a}.jsonl",
            rollout(@id_a)
          )

        assert {:ok, [%SessionSummary{path: ^plain, compressed?: false}]} =
                 History.list_sessions(history)
      end

      test "lines split across decompression chunks are rejoined", %{tmp_dir: dir} do
        long = String.duplicate("x", 200_000)

        contents =
          Enum.map_join(1..5, "\n", &line("event_msg", %{"n" => &1, "text" => long})) <> "\n"

        path = write(dir, "big.jsonl.zst", compress(contents))

        assert Enum.map(History.stream_entries(path), & &1.payload["n"]) == [1, 2, 3, 4, 5]
      end

      test "a last line without a newline is kept", %{tmp_dir: dir} do
        path = write(dir, "tail.jsonl.zst", compress(line("a", 1) <> "\n" <> line("b", 2)))
        assert Enum.map(History.stream_entries(path), & &1.type) == ["a", "b"]
      end
    end
  end

  test "read_session/2 resolves the id when it is called", %{tmp_dir: dir} do
    history = History.at(dir)

    old =
      write(dir, "sessions/2026/11/01/rollout-2026-11-01T09-00-00-#{@id_a}.jsonl", rollout(@id_a))

    {:ok, summary} = History.find_session(history, @id_a)

    File.mkdir_p!(Path.join(dir, "archived_sessions"))
    new = Path.join(dir, "archived_sessions/rollout-2026-11-01T09-00-00-#{@id_a}.jsonl")
    File.rename!(old, new)

    assert summary.path == old
    assert {:ok, %SessionLog{path: ^new}} = History.read_session(history, @id_a)
  end
end
