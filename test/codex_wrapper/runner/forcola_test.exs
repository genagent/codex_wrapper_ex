defmodule CodexWrapper.Runner.ForcolaTest do
  use ExUnit.Case, async: true

  # Drives the real forcola shim; skipped when it is not resolvable.
  @moduletag :forcola

  alias CodexWrapper.Runner.Forcola

  # Whether an OS process is still alive (kill -0 succeeds).
  defp os_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  describe "run/4" do
    test "returns stdout and a zero exit on success" do
      assert {:ok, {"hi\n", 0}} = Forcola.run("echo", ["hi"], [], 5_000)
    end

    test "a non-zero exit is a result, not an error" do
      assert {:ok, {_stdout, 7}} = Forcola.run("sh", ["-c", "exit 7"], [], 5_000)
    end

    test "merges stderr into stdout when stderr_to_stdout is set" do
      assert {:ok, {out, 0}} =
               Forcola.run(
                 "sh",
                 ["-c", "echo out; echo err 1>&2"],
                 [stderr_to_stdout: true],
                 5_000
               )

      assert out =~ "out"
      assert out =~ "err"
    end

    test "a timeout returns {:error, :timeout}" do
      assert {:error, :timeout} = Forcola.run("sleep", ["10"], [], 300)
    end

    test "a missing binary returns a spawn error" do
      assert {:error, {:spawn, _reason}} =
               Forcola.run("definitely-not-a-real-binary-xyz", [], [], 5_000)
    end

    @tag :forcola_kill
    test "kills the child's process group on timeout (closes #33)" do
      pidfile = Path.join(System.tmp_dir!(), "cxw_forcola_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(pidfile) end)

      # The child records its pid, then sleeps well past the timeout.
      assert {:error, :timeout} =
               Forcola.run("sh", ["-c", "echo $$ > #{pidfile}; sleep 30"], [], 500)

      # Forcola confirms the group is dead before run/4 returns, so the
      # recorded process must already be gone -- no leaked CLI.
      pid = pidfile |> File.read!() |> String.trim()
      refute os_alive?(pid), "expected pid #{pid} to be killed on timeout, but it is alive"
    end
  end
end
