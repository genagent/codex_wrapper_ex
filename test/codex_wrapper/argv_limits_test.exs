defmodule CodexWrapper.ArgvLimitsTest do
  use ExUnit.Case, async: false

  alias CodexWrapper.{Argv, Command}
  alias CodexWrapper.Runner.Port

  @moduletag :tmp_dir
  @cache_key {Argv, :limits}
  @environment_key "CODEX_WRAPPER_ARGV_LIMIT_TEST"

  setup do
    original_limits = :persistent_term.get(@cache_key, nil)
    original_path = System.get_env("PATH")
    original_environment = System.get_env(@environment_key)
    :persistent_term.erase(@cache_key)

    on_exit(fn ->
      if original_limits,
        do: :persistent_term.put(@cache_key, original_limits),
        else: :persistent_term.erase(@cache_key)

      restore_env("PATH", original_path)
      restore_env(@environment_key, original_environment)
    end)

    :ok
  end

  test "finds getconf on PATH and caches discovery across target and launcher checks", %{
    tmp_dir: directory
  } do
    calls = Path.join(directory, "calls")

    executable =
      getconf(directory, """
      printf '%s\\n' "$1" >> #{Command.shell_escape(calls)}
      case "$1" in
        ARG_MAX) printf '500000\\n' ;;
        PAGESIZE) printf '4096\\n' ;;
      esac
      """)

    System.put_env("PATH", directory)
    assert %{total: 500_000} = limits = Argv.limits()
    File.rm!(executable)

    for _ <- 1..3 do
      assert Argv.limits() == limits
      assert :ok = Argv.validate("/bin/true", [], [])
      assert {:ok, {"", 0}} = Port.run("/bin/sh", ["-c", "exit 0"], [], 1_000)
      assert [] = Port.stream_lines("/bin/sh", ["-c", "exit 0"], [], 1_000) |> Enum.to_list()
    end

    expected = if :os.type() == {:unix, :linux}, do: ["PAGESIZE", "ARG_MAX"], else: ["ARG_MAX"]
    assert calls |> File.read!() |> String.split("\n", trim: true) == expected
  end

  test "unavailable getconf uses usable Linux and Darwin limits", %{tmp_dir: directory} do
    missing = Path.join(directory, "missing-getconf")
    linux = Argv.discover_limits({:unix, :linux}, missing)
    darwin = Argv.discover_limits({:unix, :darwin}, missing)
    assert linux == %{total: 2_097_152, string: 131_072}
    assert darwin == %{total: 1_048_576, string: nil}

    for limits <- [linux, darwin] do
      assert :ok =
               Argv.validate(
                 "/bin/true",
                 [],
                 [env_mode: :replace, env: [{@environment_key, String.duplicate("x", 40_000)}]],
                 limits
               )
    end
  end

  test "failed or malformed getconf results use platform defaults", %{tmp_dir: directory} do
    for script <- ["exit 1", "printf 'unknown\\n'", "printf '0\\n'", "printf '%s\\n' -1"] do
      executable = getconf(directory, script)

      assert Argv.discover_limits({:unix, :linux}, executable) ==
               %{total: 2_097_152, string: 131_072}

      assert Argv.discover_limits({:unix, :darwin}, executable) ==
               %{total: 1_048_576, string: nil}
    end
  end

  test "failed discovery does not reject small commands with a 40 KiB inherited environment", %{
    tmp_dir: directory
  } do
    getconf(directory, "exit 1")
    System.put_env("PATH", directory)
    System.put_env(@environment_key, String.duplicate("x", 40_000))

    assert {:ok, {"", 0}} = Port.run("/bin/sh", ["-c", "exit 0"], [], 1_000)
    assert [] = Port.stream_lines("/bin/sh", ["-c", "exit 0"], [], 1_000) |> Enum.to_list()
  end

  defp getconf(directory, script) do
    executable = Path.join(directory, "getconf")
    File.write!(executable, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(executable, 0o700)
    executable
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
