defmodule CodexWrapper.ExecLevel do
  @moduledoc false

  # Options `codex exec` reads before a subcommand and applies to
  # `exec resume`, `exec fork` and `exec review`, plus the config fields the
  # builders fold into `-c`. Shared by ExecResume, ExecFork and Review.
  #
  # Measured on codex-cli 0.165.0: `--profile`, `--add-dir`, `--oss`,
  # `--local-provider`, `--color`, `--approve-for-me` and `--cd` parse
  # before each subcommand and are rejected after it. `--thread-source`,
  # `--cyber-access-program` and `--worktree` belong after the subcommand.
  #
  # The builders keep the exec-level options in one `exec_level` field so
  # their structs stay under 32 fields.

  @type color_mode :: :always | :never | :auto

  @type t :: %__MODULE__{
          profile: String.t() | nil,
          add_dirs: [String.t()],
          cd: String.t() | nil,
          oss: boolean(),
          local_provider: String.t() | nil,
          color: color_mode() | nil,
          approve_for_me: boolean()
        }

  defstruct [
    :profile,
    :cd,
    :local_provider,
    :color,
    add_dirs: [],
    oss: false,
    approve_for_me: false
  ]

  @doc false
  @spec args(String.t(), t()) :: [String.t()]
  def args(subcommand, %__MODULE__{} = level) do
    ["exec"]
    |> add_bool("--oss", level.oss)
    |> add_opt("--local-provider", level.local_provider)
    |> add_opt("--profile", level.profile)
    |> add_bool("--approve-for-me", level.approve_for_me)
    |> add_opt("--cd", level.cd)
    |> add_list("--add-dir", level.add_dirs)
    |> add_opt("--color", format_color(level.color))
    |> Kernel.++([subcommand])
  end

  @doc false
  # Flags after the subcommand. A builder without the field emits nothing.
  @spec subcommand_args([String.t()], map()) :: [String.t()]
  def subcommand_args(args, command) do
    args
    |> add_bool("--worktree", Map.get(command, :worktree, false))
    |> add_opt("--thread-source", Map.get(command, :thread_source))
    |> add_opt(
      "--cyber-access-program",
      format_cyber_access_program(Map.get(command, :cyber_access_program))
    )
  end

  @doc false
  # `-c` fields for the typed approval policy and web search builders.
  # Callers append these after the user's own `config/2` entries.
  @spec config_overrides(map()) :: [String.t()]
  def config_overrides(command) do
    approval_override(command.approval_policy) ++ web_search_override(command.search)
  end

  defp approval_override(nil), do: []
  defp approval_override(policy), do: [~s(approval_policy="#{format_approval_policy(policy)}")]

  defp web_search_override(nil), do: []
  defp web_search_override(mode), do: [~s(web_search="#{mode}")]

  defp format_approval_policy(:untrusted), do: "untrusted"
  defp format_approval_policy(:on_request), do: "on-request"
  defp format_approval_policy(:never), do: "never"

  defp format_color(nil), do: nil
  defp format_color(mode) when mode in [:always, :never, :auto], do: Atom.to_string(mode)

  defp format_cyber_access_program(nil), do: nil

  defp format_cyber_access_program(program)
       when program in [:standard, :daybreak_blue, :daybreak_red],
       do: Atom.to_string(program)

  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, value]
  defp add_bool(args, _flag, false), do: args
  defp add_bool(args, flag, true), do: args ++ [flag]
  defp add_list(args, _flag, []), do: args
  defp add_list(args, flag, values), do: args ++ Enum.flat_map(values, &[flag, &1])
end
