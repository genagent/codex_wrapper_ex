defmodule CodexWrapper.RunnerTest do
  # Not async: one test overrides the :runner application env.
  use ExUnit.Case, async: false

  alias CodexWrapper.Runner

  describe "impl/0" do
    test "defaults to Runner.Port" do
      assert Runner.impl() == CodexWrapper.Runner.Port
    end

    test "honors the :runner application env" do
      Application.put_env(:codex_wrapper, :runner, CodexWrapper.Runner.Forcola)
      on_exit(fn -> Application.delete_env(:codex_wrapper, :runner) end)

      assert Runner.impl() == CodexWrapper.Runner.Forcola
    end
  end

  describe "Runner.Port.run/4" do
    alias CodexWrapper.Runner.Port

    test "returns stdout and exit code on completion" do
      assert {:ok, {"hi\n", 0}} = Port.run("echo", ["hi"], [], nil)
    end

    test "surfaces a non-zero exit code" do
      assert {:ok, {_out, 5}} = Port.run("sh", ["-c", "exit 5"], [], nil)
    end

    test "merges stderr into stdout" do
      assert {:ok, {out, 0}} = Port.run("sh", ["-c", "echo out; echo err 1>&2"], [], nil)
      assert out =~ "out"
      assert out =~ "err"
    end

    test "a timeout returns {:error, :timeout}" do
      assert {:error, :timeout} = Port.run("sleep", ["10"], [], 200)
    end
  end
end
