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

  It also lists the long flags each subcommand's help shows that no
  builder emits, minus an explicit allowlist, so a flag codex adds is
  reported too.

  Flags added after the oldest pinned CLI carry the first version they
  are known in; on an older CLI the emitted-flag check skips them.

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

  alias CodexWrapper.{Exec, ExecFork, ExecResume, Review}

  @requirements ["app.start"]

  @enum_config_keys ~w(approval_policy web_search sandbox_mode)
  @sentinel "__codex_wrapper_contract_probe__"

  # First codex-cli version each flag is known in, for flags newer than the
  # oldest pinned CLI (0.149.0). Checked against cached release binaries.
  @introduced %{
    "--worktree" => {0, 157, 1},
    "--thread-source" => {0, 157, 1},
    "--cyber-access-program" => {0, 162, 0}
  }

  # Help flags no builder emits, by subcommand, with the reason.
  @unbuilt_allowlist %{
    "exec" => %{
      "--help" => "help",
      "--version" => "version",
      "--config" => "emitted as -c",
      "--last" => "appears in help text about exec resume"
    },
    "exec resume" => %{
      "--help" => "help",
      "--config" => "emitted as -c",
      "--worktree" => "pending #143",
      "--thread-source" => "pending #143",
      "--cyber-access-program" => "pending #143"
    },
    "exec fork" => %{
      "--help" => "help",
      "--config" => "emitted as -c",
      "--worktree" => "pending #143",
      "--thread-source" => "pending #143",
      "--cyber-access-program" => "pending #143"
    },
    "exec review" => %{
      "--help" => "help",
      "--config" => "emitted as -c",
      "--worktree" => "pending #143",
      "--thread-source" => "pending #143",
      "--cyber-access-program" => "listed, but help says it is not supported with review"
    }
  }

  # Each entry: {label, argv the builder produces}. Built maximally so
  # every option this wrapper can emit shows up in the arg list. Options
  # codex rejects together get a second entry for the same subcommand.
  defp specs do
    [
      {"exec", Exec.args(maximal_exec())},
      {"exec", Exec.args(maximal_exec_exclusive())},
      {"exec resume", ExecResume.args(maximal_exec_resume())},
      {"exec fork", ExecFork.args(maximal_exec_fork())},
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
    |> Exec.profile("contract")
    |> Exec.dangerously_bypass_hook_trust()
    |> Exec.strict_config()
    |> Exec.ignore_user_config()
    |> Exec.ignore_rules()
    |> Exec.color(:never)
    |> Exec.oss()
    |> Exec.local_provider("ollama")
    |> Exec.dangerously_bypass_approvals_and_sandbox()
    |> Exec.thread_source("contract")
    |> Exec.cyber_access_program(:standard)
  end

  # --approve-for-me excludes --sandbox and the bypass flag, and
  # --worktree excludes --ephemeral, so they get their own command.
  defp maximal_exec_exclusive do
    Exec.new("prompt")
    |> Exec.approve_for_me()
    |> Exec.worktree()
  end

  defp maximal_exec_resume do
    ExecResume.new()
    |> ExecResume.session_id("abc-123")
    |> ExecResume.prompt("continue")
    |> ExecResume.model("gpt-5")
    |> ExecResume.last()
    |> ExecResume.skip_git_repo_check()
    |> ExecResume.ephemeral()
    |> ExecResume.output_schema("/tmp/schema.json")
    |> ExecResume.json()
    |> ExecResume.output_last_message("/tmp/last.txt")
    |> ExecResume.all()
    |> ExecResume.sandbox(:read_only)
    |> ExecResume.approval_policy(:never)
    |> ExecResume.image("/tmp/a.png")
    |> ExecResume.enable("some-feature")
    |> ExecResume.disable("other-feature")
    |> ExecResume.strict_config()
    |> ExecResume.dangerously_bypass_approvals_and_sandbox()
    |> ExecResume.dangerously_bypass_hook_trust()
    |> ExecResume.ignore_user_config()
    |> ExecResume.ignore_rules()
  end

  defp maximal_exec_fork do
    ExecFork.new("abc-123")
    |> ExecFork.prompt("branch off")
    |> ExecFork.model("gpt-5")
    |> ExecFork.sandbox(:read_only)
    |> ExecFork.enable("some-feature")
    |> ExecFork.disable("other-feature")
    |> ExecFork.image("/tmp/a.png")
    |> ExecFork.strict_config()
    |> ExecFork.dangerously_bypass_approvals_and_sandbox()
    |> ExecFork.dangerously_bypass_hook_trust()
    |> ExecFork.skip_git_repo_check()
    |> ExecFork.ephemeral()
    |> ExecFork.ignore_user_config()
    |> ExecFork.ignore_rules()
    |> ExecFork.output_schema("/tmp/schema.json")
    |> ExecFork.json()
    |> ExecFork.output_last_message("/tmp/last.txt")
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
    |> Review.output_schema("/tmp/schema.json")
    |> Review.output_last_message("/tmp/last.txt")
    |> Review.uncommitted()
    |> Review.commit("abc123")
    |> Review.sandbox(:read_only)
    |> Review.enable("some-feature")
    |> Review.disable("other-feature")
    |> Review.strict_config()
    |> Review.dangerously_bypass_approvals_and_sandbox()
    |> Review.dangerously_bypass_hook_trust()
    |> Review.ignore_user_config()
    |> Review.ignore_rules()
  end

  @impl Mix.Task
  def run(_argv) do
    binary =
      System.get_env("CODEX_CONTRACT_BIN") || System.find_executable("codex") ||
        Mix.raise("codex not found; set CODEX_CONTRACT_BIN or put it on PATH")

    verify_version!(version(binary), System.get_env("CODEX_CONTRACT_VERSION"))

    Mix.shell().info("codex: #{binary}")
    Mix.shell().info(version(binary))
    Mix.shell().info("")

    findings =
      check(binary, specs(), version: parse_version(version(binary))) ++
        unbuilt(binary, specs())

    if findings == [] do
      Mix.shell().info("No drift: every emitted flag is still accepted.")
    else
      Mix.shell().error("Drift found:\n")
      Enum.each(findings, &Mix.shell().error("  " <> &1))

      Mix.shell().error("""

      A line naming a flag or config key this wrapper emits means the
      installed codex CLI no longer accepts it: fix the builder, or
      redirect the option to a config key the way #53 and #54 did. A line
      naming a help flag no builder emits means codex added an option: add
      a builder, or add it to @unbuilt_allowlist with the reason.
      """)

      exit({:shutdown, 1})
    end
  end

  @doc false
  @spec check(String.t(), [{String.t(), [String.t()]}], keyword()) :: [String.t()]
  def check(binary, commands \\ specs(), opts \\ []) do
    version = Keyword.get(opts, :version)
    Enum.flat_map(commands, &check_command(binary, &1, version))
  end

  @doc false
  # Long flags each subcommand's help lists that none of `commands` emits
  # for it and the allowlist does not cover.
  @spec unbuilt(String.t(), [{String.t(), [String.t()]}], map()) :: [String.t()]
  def unbuilt(binary, commands \\ specs(), allowlist \\ @unbuilt_allowlist) do
    commands
    |> Enum.group_by(fn {label, _argv} -> label end, fn {_label, argv} -> argv end)
    |> Enum.sort()
    |> Enum.flat_map(fn {label, argvs} ->
      emitted = argvs |> Enum.flat_map(&(&1 |> split_emitted() |> elem(0))) |> MapSet.new()
      allowed = Map.get(allowlist, label, %{})

      binary
      |> help_flags(String.split(label))
      |> Enum.filter(&String.starts_with?(&1, "--"))
      |> Enum.reject(&(MapSet.member?(emitted, &1) or Map.has_key?(allowed, &1)))
      |> Enum.sort()
      |> Enum.map(&"#{label}: #{&1} is in `codex #{label} --help` but no builder emits it")
    end)
  end

  @doc false
  @spec parse_version(String.t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  def parse_version(reported) do
    case Regex.run(~r/\b(\d+)\.(\d+)\.(\d+)\b/, reported) do
      [_, major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}

      nil ->
        nil
    end
  end

  # A flag newer than the installed CLI is expected to be missing from its
  # help; the builder documents the version it needs.
  defp introduced_after?(_flag, nil), do: false

  defp introduced_after?(flag, version) do
    case Map.fetch(@introduced, flag) do
      {:ok, introduced} -> version < introduced
      :error -> false
    end
  end

  defp verify_version!(_reported, nil), do: :ok

  defp verify_version!(reported, expected) do
    unless Regex.run(~r/\b\d+\.\d+\.\d+\b/, reported) == [expected] do
      Mix.raise("expected codex #{expected}, got: #{reported}")
    end
  end

  defp version(binary) do
    case System.cmd(binary, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, _} -> "version unknown: #{String.trim(out)}"
    end
  end

  defp check_command(binary, {label, argv}, version) do
    subcommand = String.split(label)
    {flags, config_keys} = split_emitted(argv)
    accepted = help_flags(binary, subcommand)

    missing_flags =
      flags
      |> Enum.reject(&(MapSet.member?(accepted, &1) or introduced_after?(&1, version)))
      |> Enum.map(&"#{label}: #{&1} is not in `codex #{label} --help`")

    missing_keys =
      config_keys
      |> Enum.flat_map(&check_config_key(binary, subcommand, label, &1))

    if MapSet.size(accepted) == 0 do
      ["#{label}: help returned no option flags; contract check would be blind"]
    else
      missing_flags ++ missing_keys
    end
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
  defp check_config_key(binary, subcommand, label, kv) do
    key = kv |> String.split("=", parts: 2) |> hd()

    if key in @enum_config_keys do
      probe_enum_key(binary, subcommand, label, key)
    else
      ["#{label}: refusing unsafe config probe for #{key}; add a bounded probe first"]
    end
  end

  # exec fork requires an id at clap parsing, before config is loaded. The
  # invalid enum still prevents this synthetic id from being read or forked.
  defp probe_args(["exec", "fork"]), do: ["exec", "fork", "contract-probe-session"]
  defp probe_args(subcommand), do: subcommand

  defp probe_enum_key(binary, subcommand, label, key) do
    # --help bypasses config loading. An impossible enum value fails before
    # inference and proves the key is recognized instead of accepting help's 0.
    args = probe_args(subcommand) ++ ["--strict-config", "-c", ~s(#{key}="#{@sentinel}")]
    {output, code} = System.cmd(binary, args, stderr_to_stdout: true)

    if code != 0 and String.contains?(output, @sentinel) and
         String.contains?(output, "unknown variant") do
      []
    else
      ["#{label}: #{key} did not reject the enum sentinel; config drift or blind probe"]
    end
  end
end
