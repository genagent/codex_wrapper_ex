defmodule Mix.Tasks.Codex.Contract do
  @shortdoc "Check the flags this wrapper emits against the installed codex CLI"

  @moduledoc """
  Compare every flag the builders emit against the installed `codex` CLI.

  The wrapper drifted silently once already: Codex went 0.119 to 0.145 in
  roughly three months, removing `--ask-for-approval`, `--search` and the
  `sandbox <platform>` subcommand along the way, and nothing in CI
  noticed (see #52, #64).

  This task builds a maximal command from each builder, collects the
  flags it emits, and checks each one against `codex <subcommand>
  --help`. A flag the CLI no longer lists is reported as drift.

      mix codex.contract

  Exits non-zero when drift is found, so CI can act on it.

  ## Config-key redirects

  Some options are emitted as `-c key=value` config overrides rather
  than named flags -- `approval_policy` and `web_search` both moved that
  way when their flags were removed. Config keys never appear in
  `--help`, so they are probed separately by running the subcommand with
  `--strict-config` and the override, which rejects unknown keys.

  ## What this does not check

  Flag *semantics*, value sets (an accepted flag whose allowed values
  changed is invisible here), and anything requiring authentication.
  It answers one question -- does the CLI still accept the flags we
  emit -- which is the failure mode that actually bit us.
  """

  use Mix.Task

  alias CodexWrapper.{Exec, ExecResume, Review}

  @requirements ["app.start"]

  # Each entry: {label, argv the builder produces}. Built maximally so
  # every option this wrapper can emit shows up in the arg list.
  defp specs do
    [
      {"exec", Exec.args(maximal_exec())},
      {"exec resume", ExecResume.args(maximal_exec_resume())},
      {"exec review", Review.args(maximal_review())}
    ]
  end

  defp maximal_exec do
    Exec.new("prompt")
    |> Exec.model("gpt-5")
    |> Exec.sandbox(:workspace_write)
    |> Exec.approval_policy(:never)
    |> Exec.cd("/tmp")
    |> Exec.skip_git_repo_check()
    |> Exec.add_dir("/tmp")
    |> Exec.search()
    |> Exec.ephemeral()
    |> Exec.output_schema("/tmp/schema.json")
    |> Exec.json()
    |> Exec.output_last_message("/tmp/last.txt")
    |> Exec.image("/tmp/a.png")
    |> Exec.enable("some-feature")
    |> Exec.disable("other-feature")
  end

  defp maximal_exec_resume do
    ExecResume.new()
    |> ExecResume.session_id("abc-123")
    |> ExecResume.prompt("continue")
    |> ExecResume.model("gpt-5")
    |> ExecResume.last()
    |> ExecResume.skip_git_repo_check()
    |> ExecResume.ephemeral()
    |> ExecResume.json()
    |> ExecResume.output_last_message("/tmp/last.txt")
  end

  defp maximal_review do
    Review.new()
    |> Review.prompt("look at this")
    |> Review.base("main")
    |> Review.model("gpt-5")
    |> Review.title("a title")
    |> Review.skip_git_repo_check()
    |> Review.ephemeral()
    |> Review.json()
    |> Review.output_last_message("/tmp/last.txt")
  end

  @impl Mix.Task
  def run(_argv) do
    binary = System.find_executable("codex") || Mix.raise("codex not found on PATH")

    Mix.shell().info("codex: #{binary}")
    Mix.shell().info(version(binary))
    Mix.shell().info("")

    findings = Enum.flat_map(specs(), &check(binary, &1))

    if findings == [] do
      Mix.shell().info("No drift: every emitted flag is still accepted.")
    else
      Mix.shell().error("Drift found:\n")
      Enum.each(findings, &Mix.shell().error("  " <> &1))

      Mix.shell().error("""

      Each line is a flag or config key this wrapper emits that the
      installed codex CLI no longer accepts. Fix the builder, or redirect
      the option to a config key the way #53 and #54 did.
      """)

      exit({:shutdown, 1})
    end
  end

  defp version(binary) do
    case System.cmd(binary, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, _} -> "version unknown: #{String.trim(out)}"
    end
  end

  defp check(binary, {label, argv}) do
    subcommand = String.split(label)
    {flags, config_keys} = split_emitted(argv)
    accepted = help_flags(binary, subcommand)

    missing_flags =
      flags
      |> Enum.reject(&MapSet.member?(accepted, &1))
      |> Enum.map(&"#{label}: #{&1} is not in `codex #{label} --help`")

    missing_keys =
      config_keys
      |> Enum.reject(&config_key_accepted?(binary, subcommand, &1))
      |> Enum.map(&"#{label}: -c #{&1} was rejected under --strict-config")

    missing_flags ++ missing_keys
  end

  # Walk the argv, separating named flags from the `-c key=value` pairs.
  # A flag's *value* must not be mistaken for a flag, so `-c` and any
  # option taking a value consume the next element.
  defp split_emitted(argv), do: split_emitted(argv, [], [])

  defp split_emitted([], flags, keys), do: {Enum.uniq(flags), Enum.uniq(keys)}

  defp split_emitted(["-c", kv | rest], flags, keys),
    do: split_emitted(rest, flags, [kv | keys])

  defp split_emitted(["--" | _rest], flags, keys), do: split_emitted([], flags, keys)

  defp split_emitted([arg | rest], flags, keys) do
    if String.starts_with?(arg, "-") do
      split_emitted(rest, [arg | flags], keys)
    else
      split_emitted(rest, flags, keys)
    end
  end

  # Every `--flag` / `-f` token the subcommand's help text mentions.
  defp help_flags(binary, subcommand) do
    {out, _} = System.cmd(binary, subcommand ++ ["--help"], stderr_to_stdout: true)

    ~r/(?<![\w-])(--?[a-zA-Z][\w-]*)/
    |> Regex.scan(out)
    |> Enum.map(fn [_, flag] -> flag end)
    |> MapSet.new()
  end

  # `--strict-config` rejects unknown config keys. `--help` short-circuits
  # before the run, so this costs nothing and needs no auth.
  defp config_key_accepted?(binary, subcommand, kv) do
    args = subcommand ++ ["--strict-config", "-c", kv, "--help"]

    case System.cmd(binary, args, stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end
end
