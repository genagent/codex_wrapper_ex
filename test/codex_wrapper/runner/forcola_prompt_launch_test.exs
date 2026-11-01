defmodule CodexWrapper.Runner.ForcolaPromptLaunchTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Runner.Forcola

  @moduletag :forcola
  @moduletag :tmp_dir

  test "stdin launcher retains typed failures for missing and non-executable targets", context do
    missing = Path.join(context.tmp_dir, "missing")
    blocked = Path.join(context.tmp_dir, "blocked")
    File.write!(blocked, "#!/bin/sh\nexit 0\n")
    File.chmod!(blocked, 0o600)

    for binary <- [missing, blocked] do
      assert {:error, {:spawn, _}} = Forcola.run(binary, [], [stdin: "prompt"], 1_000)

      assert [{:error, {:spawn, _}}] =
               Forcola.stream_lines(binary, [], [stdin: "prompt"], 1_000) |> Enum.to_list()
    end
  end

  test "a started target's exit 127 remains its exit status", context do
    binary = executable(context, "failure", "exit 127")
    assert {:ok, {"", 127}} = Forcola.run(binary, [], [stdin: "prompt"], 1_000)

    assert [{:error, {:exit_status, 127}}] =
             Forcola.stream_lines(binary, [], [stdin: "prompt"], 1_000) |> Enum.to_list()
  end

  test "evidenced executable failures retain spawn termination without a child status", context do
    config =
      CodexWrapper.Config.new(
        binary: Path.join(context.tmp_dir, "missing"),
        runner: Forcola
      )

    ref = make_ref()

    assert {:error, {:spawn, reason}} =
             CodexWrapper.Exec.execute(CodexWrapper.Exec.new("prompt"), config,
               execution_observer: {self(), ref}
             )

    assert_receive {^ref,
                    %CodexWrapper.ExecutionObservation{
                      termination: {:spawn, ^reason},
                      child_status: nil,
                      child_signal: nil
                    }}

    assert {{:error, {:invalid_argument, 1}}, %{termination: :pre_spawn}} =
             Forcola.run_evidenced("/bin/true", [<<0>>], [stdin: "prompt"], 1_000, {self(), ref})
  end

  test "relative targets and PATH entries resolve against the child working directory", context do
    executable(context, "prompt-reader", "/bin/cat")

    for {binary, env} <- [
          {"./prompt-reader", []},
          {"prompt-reader", [{"PATH", context.tmp_dir}]},
          {"prompt-reader", [{"PATH", "."}]},
          {"prompt-reader", [{"PATH", ""}]},
          {"prompt-reader", [{"PATH", "/missing"}, {"PATH", "."}]}
        ] do
      opts = [stdin: "prompt\n", cd: context.tmp_dir, env: env]
      assert {:ok, {"prompt\n", 0}} = Forcola.run(binary, [], opts, 1_000)
      assert ["prompt"] = Forcola.stream_lines(binary, [], opts, 1_000) |> Enum.to_list()
    end
  end

  test "replaced or unset PATH uses the system default search path", context do
    executable(context, "prompt-reader", "/bin/cat")

    for env <- [[{"PATH", false}], [{"PATH", nil}], [{"PATH", "/missing"}, {"PATH", false}]] do
      opts = [stdin: "prompt\n", env: env]
      assert {:ok, {"prompt\n", 0}} = Forcola.run("cat", [], opts, 1_000)
      assert ["prompt"] = Forcola.stream_lines("cat", [], opts, 1_000) |> Enum.to_list()
    end

    assert {:ok, {"prompt\n", 0}} =
             Forcola.run("cat", [], [stdin: "prompt\n", env_mode: :replace], 1_000)

    assert {:ok, {"prompt\n", 0}} =
             Forcola.run(
               "prompt-reader",
               [],
               [stdin: "prompt\n", env_mode: :replace, env: [{"PATH", context.tmp_dir}]],
               1_000
             )

    assert {:error, {:spawn, _}} =
             Forcola.run("cat", [], [stdin: "prompt", env: [{"PATH", context.tmp_dir}]], 1_000)
  end

  test "relative executable lookup retains filesystem symlink traversal", context do
    executable(context, "prompt-reader", "/bin/cat")
    nested = Path.join(context.tmp_dir, "nested")
    File.mkdir!(nested)
    link = Path.join(nested, "link")
    File.ln_s!(nested, link)
    opts = [stdin: "prompt\n", cd: link]

    assert {:ok, {"prompt\n", 0}} = Forcola.run("../prompt-reader", [], opts, 1_000)

    assert ["prompt"] =
             Forcola.stream_lines("../prompt-reader", [], opts, 1_000) |> Enum.to_list()
  end

  test "a deleted VM cwd returns typed spawn errors for inherited and relative working directories",
       context do
    code = deleted_cwd_probe(context.tmp_dir)

    paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++ paths ++ ["-e", code],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "deleted cwd checks passed"
  end

  defp deleted_cwd_probe(directory) do
    """
    alias CodexWrapper.Runner.Forcola, as: Runner
    {:ok, _} = Application.ensure_all_started(:codex_wrapper)
    original = File.cwd!()
    directory = #{inspect(directory)}
    removed = Path.join(directory, "removed")
    File.mkdir!(removed)
    File.cd!(removed)
    File.rmdir!(removed)

    try do
      {:error, :enoent} = File.cwd()
      target = {self(), make_ref()}

      for cwd <- [nil, ".", "relative"] do
        opts = [stdin: "prompt", cd: cwd]
        {:error, {:spawn, {:cwd, :enoent}}} = Runner.run("/bin/cat", [], opts, 1_000)

        [{:error, {:spawn, {:cwd, :enoent}}}] =
          Runner.stream_lines("/bin/cat", [], opts, 1_000) |> Enum.to_list()

        {:error, {:spawn, {:cwd, :enoent}}} =
          Runner.run_observed("/bin/cat", [], opts, 1_000, target)

        {{:error, {:spawn, {:cwd, :enoent}}}, %{termination: {:spawn, {:cwd, :enoent}}}} =
          Runner.run_evidenced("/bin/cat", [], opts, 1_000, target)
      end

      IO.puts("deleted cwd checks passed")
    after
      File.cd!(original)
    end
    """
  end

  defp executable(context, name, body) do
    path = Path.join(context.tmp_dir, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o700)
    path
  end
end
