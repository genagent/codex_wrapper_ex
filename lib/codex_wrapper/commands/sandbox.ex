defmodule CodexWrapper.Commands.Sandbox do
  @moduledoc """
  Sandbox command -- run a command inside the Codex sandbox.

  Wraps `codex sandbox <platform> -- <command> [args...]`.

  ## Usage

      config = CodexWrapper.Config.new()

      # Run ls inside a macOS sandbox
      sandbox = CodexWrapper.Commands.Sandbox.new(:macos, "ls")
        |> CodexWrapper.Commands.Sandbox.arg("-la")

      {:ok, output} = CodexWrapper.Commands.Sandbox.execute(sandbox, config)
  """

  alias CodexWrapper.Config

  @type platform :: :macos | :linux | :windows

  @type t :: %__MODULE__{
          platform: platform(),
          command: String.t(),
          command_args: [String.t()]
        }

  defstruct [:platform, :command, command_args: []]

  # --- Constructor ---

  @doc """
  Create a sandbox command for the given platform and command.
  """
  @spec new(platform(), String.t()) :: t()
  def new(platform, command) when platform in [:macos, :linux, :windows] and is_binary(command) do
    %__MODULE__{platform: platform, command: command}
  end

  # --- Builder functions ---

  @doc "Add an argument to the sandboxed command."
  @spec arg(t(), String.t()) :: t()
  def arg(%__MODULE__{} = s, arg), do: %{s | command_args: s.command_args ++ [arg]}

  @doc "Add multiple arguments to the sandboxed command."
  @spec args(t(), [String.t()]) :: t()
  def args(%__MODULE__{} = s, args) when is_list(args),
    do: %{s | command_args: s.command_args ++ args}

  # --- Execution ---

  @doc """
  Execute the sandbox command synchronously.
  """
  @spec execute(t(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def execute(%__MODULE__{} = sandbox, %Config{} = config) do
    all_args = Config.base_args(config) ++ build_args(sandbox)

    case System.cmd(config.binary, all_args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  # --- Arg building ---

  @doc """
  Build the argument list for this command.
  """
  @spec build_args(t()) :: [String.t()]
  def build_args(%__MODULE__{} = s) do
    ["sandbox", format_platform(s.platform), "--", s.command] ++ s.command_args
  end

  defp format_platform(:macos), do: "macos"
  defp format_platform(:linux), do: "linux"
  defp format_platform(:windows), do: "windows"
end
