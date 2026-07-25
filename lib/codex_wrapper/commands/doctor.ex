defmodule CodexWrapper.Commands.Doctor do
  @moduledoc """
  Doctor command -- diagnose the local Codex install, config, auth, and
  runtime health.

  Wraps `codex doctor [OPTIONS]`. Useful as a preflight before a run:
  it reports whether the CLI is installed, whether auth is configured,
  and whether the configured provider endpoints are reachable.

  ## Usage

      config = CodexWrapper.Config.new()

      {:ok, report} = CodexWrapper.Commands.Doctor.execute(Doctor.new(), config)

  For a machine-readable report, use `execute_json/2`:

      {:ok, report} = CodexWrapper.Commands.Doctor.execute_json(Doctor.new(), config)

      report["overallStatus"]
      #=> "ok"

  ## Exit status

  `codex doctor` exits 0 even when checks report warnings or failures, so
  a successful call is not by itself a clean bill of health. Read
  `"overallStatus"` from the JSON report (`"ok"`, `"warning"`, ...) rather
  than relying on the exit code.
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config}

  @type t :: %__MODULE__{
          json: boolean(),
          summary: boolean(),
          all: boolean(),
          no_color: boolean(),
          ascii: boolean()
        }

  defstruct json: false,
            summary: false,
            all: false,
            no_color: false,
            ascii: false

  # --- Constructor ---

  @doc """
  Create a doctor command with every option unset.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # --- Builder functions ---

  @doc "Emit a redacted machine-readable report (`--json`)."
  @spec json(t()) :: t()
  def json(%__MODULE__{} = d), do: %{d | json: true}

  @doc "Show only grouped check rows and the final count summary (`--summary`)."
  @spec summary(t()) :: t()
  def summary(%__MODULE__{} = d), do: %{d | summary: true}

  @doc "Expand long lists in detailed human output (`--all`)."
  @spec all(t()) :: t()
  def all(%__MODULE__{} = d), do: %{d | all: true}

  @doc "Disable ANSI color in human output (`--no-color`)."
  @spec no_color(t()) :: t()
  def no_color(%__MODULE__{} = d), do: %{d | no_color: true}

  @doc "Use ASCII status labels and separators in human output (`--ascii`)."
  @spec ascii(t()) :: t()
  def ascii(%__MODULE__{} = d), do: %{d | ascii: true}

  # --- Execution ---

  @doc """
  Run the diagnostics synchronously, returning the report as a string.

  The human-readable report is a display format, not a stable contract.
  Use `execute_json/2` when the caller needs to inspect the result.
  """
  @spec execute(t(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def execute(%__MODULE__{} = doctor, %Config{} = config) do
    Command.run(__MODULE__, doctor, config)
  end

  @doc """
  Run the diagnostics with `--json` and return the decoded report.

  Forces `--json` on the command. The report is a map keyed by
  `"schemaVersion"`, `"overallStatus"`, `"codexVersion"`, and `"checks"`.
  """
  @spec execute_json(t(), Config.t()) :: {:ok, map()} | {:error, term()}
  def execute_json(%__MODULE__{} = doctor, %Config{} = config) do
    case execute(%{doctor | json: true}, config) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, report} -> {:ok, report}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  # --- Arg building ---

  @doc """
  Build the argument list for this command.
  """
  @spec build_args(t()) :: [String.t()]
  def build_args(%__MODULE__{} = d), do: args(d)

  @impl true
  def args(%__MODULE__{} = d) do
    ["doctor"]
    |> add_bool("--json", d.json)
    |> add_bool("--summary", d.summary)
    |> add_bool("--all", d.all)
    |> add_bool("--no-color", d.no_color)
    |> add_bool("--ascii", d.ascii)
  end

  @impl true
  def parse_output(stdout, 0), do: {:ok, String.trim(stdout)}
  def parse_output(stdout, exit_code), do: {:error, {:exit, exit_code, stdout}}

  # --- Arg helpers ---

  defp add_bool(args, _flag, false), do: args
  defp add_bool(args, flag, true), do: args ++ [flag]
end
