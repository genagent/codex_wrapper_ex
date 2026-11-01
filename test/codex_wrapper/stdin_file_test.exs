defmodule CodexWrapper.StdinFileTest do
  use ExUnit.Case, async: false

  alias CodexWrapper.StdinFile

  test "creates a 0600 prompt inside a 0700 directory and removes both after use" do
    prompt = "private prompt\nλ\0"

    path =
      StdinFile.with_file([stdin: prompt], fn path ->
        assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
        assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
        assert File.read!(path) == prompt
        path
      end)

    assert_removed(path)
  end

  test "concurrent callers hold distinct random directory names" do
    owner = self()
    ref = make_ref()

    tasks =
      for number <- 1..24 do
        Task.async(fn ->
          prompt = "private prompt #{number}"

          StdinFile.with_file([stdin: prompt], fn path ->
            assert File.read!(path) == prompt
            send(owner, {ref, self(), path})

            receive do
              {^ref, :release} -> path
            after
              10_000 -> raise "concurrent prompt test did not release its file"
            end
          end)
        end)
      end

    try do
      paths =
        Enum.map(tasks, fn task ->
          pid = task.pid
          assert_receive {^ref, ^pid, path}, 5_000
          path
        end)

      assert length(Enum.uniq(paths)) == length(tasks)

      for path <- paths do
        suffix =
          path
          |> Path.dirname()
          |> Path.basename()
          |> String.replace_prefix("codex-wrapper-stdin-", "")

        assert {:ok, <<_random::binary-size(16)>>} = Base.url_decode64(suffix, padding: false)
        assert File.exists?(path)
      end
    after
      Enum.each(tasks, &send(&1.pid, {ref, :release}))
    end

    Enum.each(tasks, fn task -> task |> Task.await(5_000) |> assert_removed() end)
  end

  @tag :tmp_dir
  test "a directory collision retries without changing the existing directory", %{tmp_dir: dir} do
    occupied = Path.join(dir, "occupied")
    available = Path.join(dir, "available")
    File.mkdir!(occupied)
    marker = Path.join(occupied, "prompt")
    File.write!(marker, "another caller's prompt")
    ref = make_ref()

    next_directory = fn ->
      if File.exists?(Path.join(dir, "attempted")) do
        send(self(), {ref, available})
        available
      else
        File.touch!(Path.join(dir, "attempted"))
        send(self(), {ref, occupied})
        occupied
      end
    end

    path =
      StdinFile.with_file(
        [stdin: "private"],
        fn path ->
          assert File.read!(path) == "private"
          path
        end,
        next_directory
      )

    assert_receive {^ref, ^occupied}
    assert_receive {^ref, ^available}
    refute_received {^ref, _}
    assert path == Path.join(available, "prompt")
    assert_removed(path)
    assert File.read!(marker) == "another caller's prompt"
  end

  @tag :tmp_dir
  test "repeated collisions stop after five attempts without running the callback", %{
    tmp_dir: dir
  } do
    occupied = Path.join(dir, "occupied")
    File.mkdir!(occupied)
    marker = Path.join(occupied, "prompt")
    File.write!(marker, "another caller's prompt")
    ref = make_ref()

    next_directory = fn ->
      send(self(), {ref, :attempt})
      occupied
    end

    assert {:error, {:stdin_file, {:create, 1}}} =
             StdinFile.with_file(
               [stdin: "private"],
               fn _path ->
                 flunk("a collision must not hand the existing prompt to the callback")
               end,
               next_directory
             )

    for _ <- 1..5, do: assert_receive({^ref, :attempt})
    refute_received {^ref, :attempt}
    assert File.read!(marker) == "another caller's prompt"
  end

  test "removes files when launch returns an error or raises" do
    ref = make_ref()

    assert {:error, :spawn} =
             StdinFile.with_file([stdin: "private"], fn path ->
               send(self(), {ref, path})
               {:error, :spawn}
             end)

    assert_receive {^ref, path}
    assert_removed(path)

    assert_raise RuntimeError, "launch failed", fn ->
      StdinFile.with_file([stdin: "private"], fn path ->
        send(self(), {ref, path})
        raise "launch failed"
      end)
    end

    assert_receive {^ref, path}
    assert_removed(path)
  end

  test "streams create input only when enumerated and can be enumerated again" do
    ref = make_ref()

    stream =
      StdinFile.stream([stdin: "private"], fn path ->
        send(self(), {ref, path})
        [File.read!(path)]
      end)

    refute_received {^ref, _}

    for _ <- 1..2 do
      assert Enum.to_list(stream) == ["private"]
      assert_receive {^ref, path}
      assert_removed(path)
    end
  end

  test "early stream halt closes the nested stream before removing input" do
    ref = make_ref()

    stream =
      StdinFile.stream([stdin: "private"], fn path ->
        Stream.resource(
          fn -> path end,
          fn path -> {[path], path} end,
          fn path -> send(self(), {ref, path, File.exists?(path)}) end
        )
      end)

    assert [path] = Enum.take(stream, 1)
    assert_receive {^ref, ^path, true}
    assert_removed(path)
  end

  test "stream cleanup handles errors during construction, initialization and consumption" do
    ref = make_ref()

    for stage <- [:construct, :initialize, :consume] do
      stream =
        StdinFile.stream([stdin: "private"], fn path ->
          send(self(), {ref, path})
          if stage == :construct, do: raise("stream failed")

          Stream.resource(
            fn ->
              send(self(), {ref, :initialize})
              if stage == :initialize, do: raise("stream failed")
              path
            end,
            fn _path -> raise "stream failed" end,
            fn _path -> send(self(), {ref, :closed}) end
          )
        end)

      assert_raise RuntimeError, "stream failed", fn -> Enum.to_list(stream) end
      assert_receive {^ref, path} when is_binary(path)
      assert_removed(path)

      if stage != :construct do
        assert_receive {^ref, :initialize}
        refute_received {^ref, :initialize}
      end

      if stage == :consume do
        assert_receive {^ref, :closed}
        refute_received {^ref, :closed}
      end
    end
  end

  for runner <- [CodexWrapper.Runner.Port, CodexWrapper.Runner.Forcola] do
    @runner runner
    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)
    @tag :tmp_dir

    test "#{inspect(runner)} removes input after spawn failure", %{tmp_dir: dir} do
      previous_tmpdir = System.get_env("TMPDIR")
      System.put_env("TMPDIR", dir)

      on_exit(fn ->
        if previous_tmpdir,
          do: System.put_env("TMPDIR", previous_tmpdir),
          else: System.delete_env("TMPDIR")
      end)

      before = prompt_directories()

      directory =
        Path.join(System.tmp_dir!(), "missing-codex-dir-#{System.unique_integer([:positive])}")

      opts = [stdin: "private", cd: directory]

      assert launch_failed?(@runner.run("/bin/cat", [], opts, 1_000))
      assert prompt_directories() == before
      assert [error] = @runner.stream_lines("/bin/cat", [], opts, 1_000) |> Enum.to_list()
      assert launch_failed?(error)
      assert prompt_directories() == before
    end
  end

  defp assert_removed(path) do
    refute File.exists?(path)
    refute File.exists?(Path.dirname(path))
  end

  # Depending on OTP, a failed Port chdir is surfaced as a spawn error or
  # an exit status from the port helper. Both must release the prompt file.
  defp launch_failed?({:error, {:spawn, _}}), do: true
  defp launch_failed?({:error, {:exit_status, status}}), do: status != 0
  defp launch_failed?({:ok, {"", status}}), do: status != 0
  defp launch_failed?(_result), do: false

  defp prompt_directories do
    System.tmp_dir!() |> Path.join("codex-wrapper-stdin-*") |> Path.wildcard() |> Enum.sort()
  end
end
