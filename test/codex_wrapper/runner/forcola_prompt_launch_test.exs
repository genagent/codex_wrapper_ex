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

  defp executable(context, name, body) do
    path = Path.join(context.tmp_dir, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o700)
    path
  end
end
