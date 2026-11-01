defmodule CodexWrapper.IExTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CodexWrapper.IEx, as: CIEx

  setup do
    CIEx.reset()
    :ok
  end

  describe "cost/0" do
    test "returns :no_session when no session active" do
      assert CIEx.cost() == :no_session
    end
  end

  describe "say/2" do
    test "returns :no_session when no session active" do
      assert CIEx.say("hello") == :no_session
    end
  end

  describe "session_id/0" do
    test "returns nil when no session active" do
      assert CIEx.session_id() == nil
    end
  end

  describe "last/0" do
    test "returns nil when no session active" do
      assert CIEx.last() == nil
    end
  end

  describe "history/0" do
    test "returns :no_session when no session active" do
      assert CIEx.history() == :no_session
    end
  end

  describe "reset/0" do
    test "clears state" do
      assert CIEx.reset() == :ok
    end
  end

  describe "resume/2" do
    test "sets up session state" do
      assert CIEx.resume("test-session-id") == :ok
      assert CIEx.session_id() == "test-session-id"
    end

    test "with options" do
      assert CIEx.resume("sid-123", working_dir: "/tmp") == :ok
      assert CIEx.session_id() == "sid-123"
    end
  end

  describe "module exports" do
    test "exports expected functions" do
      Code.ensure_loaded!(CIEx)
      assert {:chat, 2} in CIEx.__info__(:functions)
      assert {:say, 2} in CIEx.__info__(:functions)
      assert {:cost, 0} in CIEx.__info__(:functions)
      assert {:history, 0} in CIEx.__info__(:functions)
      assert {:reset, 0} in CIEx.__info__(:functions)
      assert {:session_id, 0} in CIEx.__info__(:functions)
      assert {:resume, 2} in CIEx.__info__(:functions)
      assert {:last, 0} in CIEx.__info__(:functions)
    end
  end

  describe "release_env" do
    @describetag :tmp_dir

    setup %{tmp_dir: directory} do
      parent = %{
        "RELEASE_ROOT" => "/release/iex-test",
        "RELEASE_COOKIE" => "iex-cookie",
        "ROOTDIR" => "/release/iex-test",
        "BINDIR" => "/release/iex-test/erts-17/bin",
        "PATH" => "/release/iex-test/bin:/release/iex-test/erts-17/bin:/usr/bin:/bin"
      }

      previous = Map.new(parent, fn {key, _value} -> {key, System.get_env(key)} end)

      on_exit(fn ->
        Enum.each(previous, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end)

      System.put_env(parent)

      binary = Path.join(directory, "fake_codex")
      report = Path.join(directory, "child-env")

      report_commands =
        Enum.map_join(parent, "\n", fn {key, _value} ->
          ~s(printf '%s\\n' "#{key}=${#{key}-<unset>}")
        end)

      File.write!(binary, """
      #!/bin/sh
      {
      #{report_commands}
      } > "$CXW_ENV_REPORT"
      printf '%s\\n' '{"type":"thread.started","thread_id":"iex-release-probe"}'
      printf '%s\\n' '{"type":"turn.completed","usage":{}}'
      """)

      File.chmod!(binary, 0o755)

      opts = [binary: binary, timeout: 10_000, env: [{"CXW_ENV_REPORT", report}]]
      %{opts: opts, report: report, parent: parent}
    end

    for policy <- [:inherit, :scrub] do
      @policy policy

      test "chat/2 retains #{@policy} for later say/2 calls", context do
        capture_io(fn ->
          opts = Keyword.put(context.opts, :release_env, @policy)
          assert CIEx.chat("hello", opts) == :ok
          assert_release_env(context, @policy)

          assert CIEx.say("next") == :ok
          assert_release_env(context, @policy)
        end)
      end

      test "resume/2 retains #{@policy} for later say/2 calls", context do
        capture_io(fn ->
          opts = Keyword.put(context.opts, :release_env, @policy)
          assert CIEx.resume("iex-release-probe", opts) == :ok

          for prompt <- ["hello", "next"] do
            assert CIEx.say(prompt) == :ok
            assert_release_env(context, @policy)
          end
        end)
      end
    end
  end

  defp assert_release_env(context, policy) do
    actual =
      context.report
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        {key, value}
      end)

    expected =
      case policy do
        :inherit -> context.parent
        :scrub -> Map.new(context.parent, fn {key, _value} -> {key, "<unset>"} end)
      end

    expected = if policy == :scrub, do: Map.put(expected, "PATH", "/usr/bin:/bin"), else: expected
    assert actual == expected
    File.rm!(context.report)
  end
end
