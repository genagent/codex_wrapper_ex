defmodule CodexWrapper.EnvUnsetTest do
  # Not async: sets a variable in the VM's environment.
  use ExUnit.Case, async: false

  alias CodexWrapper.{Config, Exec, Result}

  @moduletag :tmp_dir

  @var "CXW_PROBE_UNSET"

  setup %{tmp_dir: dir} do
    System.put_env(@var, "parent")
    on_exit(fn -> System.delete_env(@var) end)

    binary = Path.join(dir, "fake_codex")

    File.write!(binary, """
    #!/bin/sh
    printf '{"type":"probe","text":"%s"}\\n' "probe=${#{@var}-<unset>} set=${CXW_PROBE_SET-<unset>}"
    """)

    File.chmod!(binary, 0o755)
    {:ok, binary: binary}
  end

  for runner <- [CodexWrapper.Runner.Port, CodexWrapper.Runner.Forcola],
      unset <- [nil, false] do
    @runner runner
    @unset unset

    describe "#{inspect(runner)} with {name, #{inspect(unset)}}" do
      test "execute removes the variable and keeps the sets", %{binary: binary} do
        config = config(binary, @runner, [{@var, @unset}, {"CXW_PROBE_SET", "child"}])
        assert {:ok, %Result{stdout: out}} = Exec.execute(Exec.new("x"), config)
        assert out =~ "probe=<unset> set=child"
      end

      test "stream removes the variable and keeps the sets", %{binary: binary} do
        config = config(binary, @runner, [{@var, @unset}, {"CXW_PROBE_SET", "child"}])

        assert ["probe=<unset> set=child"] =
                 "x" |> Exec.new() |> Exec.stream(config) |> Enum.map(&text/1)
      end
    end
  end

  for runner <- [CodexWrapper.Runner.Port, CodexWrapper.Runner.Forcola] do
    @runner runner

    test "#{inspect(runner)} inherits the variable when nothing unsets it", %{binary: binary} do
      config = config(binary, @runner, [])
      assert {:ok, %Result{stdout: out}} = Exec.execute(Exec.new("x"), config)
      assert out =~ "probe=parent set=<unset>"
    end

    test "#{inspect(runner)} applies the last entry for a name", %{binary: binary} do
      config = config(binary, @runner, [{@var, false}, {@var, "again"}])
      assert {:ok, %Result{stdout: out}} = Exec.execute(Exec.new("x"), config)
      assert out =~ "probe=again"

      assert ["probe=again set=<unset>"] =
               "x" |> Exec.new() |> Exec.stream(config) |> Enum.map(&text/1)
    end
  end

  describe "Config.new/1" do
    test "stores nil as false" do
      assert Config.new(env: [{"A", nil}, {"B", "b"}]).env == [{"A", false}, {"B", "b"}]
    end

    test "accepts a map" do
      assert Config.new(env: %{"A" => "a"}).env == [{"A", "a"}]
    end

    test "rejects invalid entries" do
      for env <- [
            [{"", "x"}],
            [{"A=B", "x"}],
            [{"A", "x" <> <<0>>}],
            [{"A", 1}],
            [{:a, "x"}],
            ["A=x"],
            "A=x"
          ] do
        assert_raise ArgumentError, fn -> Config.new(env: env) end
      end
    end
  end

  # Non-JSON lines are dropped by the stream parser, so the fake prints
  # its report as a JSON event.
  defp text(event), do: CodexWrapper.JsonLineEvent.get(event, "text")

  defp config(binary, runner, env),
    do: Config.new(binary: binary, runner: runner, env: env, timeout: 10_000)
end
