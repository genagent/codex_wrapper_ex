defmodule CodexWrapper.Runner.StdinLauncherTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Command
  alias CodexWrapper.Runner.Forcola

  @moduletag :tmp_dir

  for runner <- [:port, :forcola] do
    @runner runner

    if runner == :forcola, do: @tag(:forcola)

    test "#{runner} stdin launcher returns after successfully opening the prompt" do
      module = if @runner == :port, do: CodexWrapper.Runner.Port, else: Forcola
      opts = [stdin: "prompt\n"]
      assert {:ok, {"prompt\n", 0}} = module.run("/bin/cat", [], opts, 5_000)
      assert ["prompt"] = module.stream_lines("/bin/cat", [], opts, 5_000) |> Enum.to_list()
    end

    test "#{runner} stdin launcher exits 125 when the prompt cannot be opened", context do
      missing = Path.join(context.tmp_dir, "missing-prompt")
      marker = Path.join(context.tmp_dir, "target-started")
      target = Path.join(context.tmp_dir, "target")
      File.write!(target, "#!/bin/sh\n: > \"$1\"\n")
      File.chmod!(target, 0o700)

      [binary | args] = launcher(@runner, target, marker, missing)
      {output, status} = System.cmd(binary, args, stderr_to_stdout: true)

      assert status == 125, output
      refute File.exists?(marker)
    end
  end

  defp launcher(:port, target, marker, missing),
    do: ["/bin/sh" | Command.shell_cmd_args(target, [marker], stdin_file: missing)]

  defp launcher(:forcola, target, marker, missing),
    do: Forcola.launch(target, [marker], missing)
end
