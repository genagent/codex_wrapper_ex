defmodule CodexWrapper.PortArgvTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Runner.Port, as: PortRunner

  @moduletag :tmp_dir

  @script ~S"""
  if IFS= read -r input; then exit 91; fi
  printf 'argc:%s\n' "$#"
  for arg do
    printf '%s:%s\n' "${#arg}" "$arg"
  done
  printf 'stderr-marker\n' >&2
  exit 7
  """

  setup %{tmp_dir: dir} do
    executable = Path.join(dir, "argv 'quoted'\t*?[x]<>\"\nprobe")
    File.write!(executable, "#!/bin/sh\n" <> @script)
    File.chmod!(executable, 0o755)
    File.write!(Path.join(dir, "glob-match"), "input\n")

    args = ["", "*", "?", "[g]*", ">created", "<glob-match", "a\tb", "'\"", "a\nb", ""]

    stdout =
      "argc:#{length(args)}\n" <>
        Enum.map_join(args, "", fn arg -> "#{byte_size(arg)}:#{arg}\n" end)

    {:ok, executable: executable, args: args, stdout: stdout}
  end

  for executable_kind <- [:path_lookup, :literal_path] do
    @executable_kind executable_kind

    test "run preserves argv, stdin EOF, output and status via #{executable_kind}", context do
      {binary, args} = invocation(@executable_kind, context)

      assert PortRunner.run(binary, args, [cd: context.tmp_dir], 5_000) ==
               {:ok, {context.stdout <> "stderr-marker\n", 7}}

      refute File.exists?(Path.join(context.tmp_dir, "created"))
    end

    test "stream preserves argv and keeps stderr separate via #{executable_kind}", context do
      {binary, args} = invocation(@executable_kind, context)

      lines =
        PortRunner.stream_lines(binary, args, [cd: context.tmp_dir], 5_000)
        |> Enum.to_list()

      # Embedded newlines become line frames; length prefixes retain argument
      # boundaries, including both literal empty arguments.
      assert lines == context.stdout |> String.split("\n") |> Enum.drop(-1)
      refute File.exists?(Path.join(context.tmp_dir, "created"))
    end
  end

  defp invocation(:path_lookup, context),
    do: {"sh", ["-c", @script, "argv-probe" | context.args]}

  defp invocation(:literal_path, context), do: {context.executable, context.args}
end
