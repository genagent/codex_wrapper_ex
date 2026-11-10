defmodule CodexWrapper.Commands.Plugin do
  @moduledoc """
  Plugin and marketplace commands.

  Wraps `codex plugin list|add|remove` and
  `codex plugin marketplace add|list|upgrade|remove`. Every call passes
  `--json` and returns the decoded JSON.

  ## Usage

      config = CodexWrapper.Config.new()

      {:ok, %{"installed" => installed, "available" => available}} =
        CodexWrapper.Commands.Plugin.list(config, available: true)

      {:ok, _} = CodexWrapper.Commands.Plugin.add(config, "sample@debug")
      {:ok, %{"marketplaces" => _}} = CodexWrapper.Commands.Plugin.marketplace_list(config)

  `add/3`, `remove/3` and the marketplace changes edit
  `$CODEX_HOME/config.toml` and the plugin cache; `list/2` with remote
  marketplaces and `marketplace_add/3` / `marketplace_upgrade/3` with Git
  sources fetch over the network.

  ## Options

  Every function takes `:config` (`key=value` overrides, `-c`), `:enable`
  and `:disable` (feature names), each a string or a list. Each function
  documents its own options too.

  ## Results

  `{:ok, decoded}` on a zero exit, `{:error, {:exit, code, output}}` on a
  non-zero exit (as `CodexWrapper.raw/2`), and `{:error, {:json, output}}`
  when the output is not JSON. An unknown option raises `ArgumentError`.
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config}

  @type action ::
          :list
          | :add
          | :remove
          | :marketplace_add
          | :marketplace_list
          | :marketplace_upgrade
          | :marketplace_remove

  @type t :: %__MODULE__{
          action: action(),
          target: String.t() | nil,
          opts: keyword()
        }

  defstruct [:action, :target, opts: []]

  @common [:config, :enable, :disable]

  # --- Plugins ---

  @doc """
  List plugins from configured and remote marketplaces.

  ## Options

    * `:marketplace` - only this marketplace (`--marketplace`)
    * `:available` - include plugins that are not installed (`--available`)
  """
  @spec list(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(%Config{} = config, opts \\ []),
    do: run(config, :list, nil, opts)

  @doc """
  Install a plugin, named `plugin` or `plugin@marketplace`.

  ## Options

    * `:marketplace` - the marketplace to install from (`--marketplace`)
  """
  @spec add(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add(%Config{} = config, plugin, opts \\ []) when is_binary(plugin),
    do: run(config, :add, plugin, opts)

  @doc """
  Uninstall a plugin and remove its local cache.

  ## Options

    * `:marketplace` - the marketplace the plugin came from (`--marketplace`)
  """
  @spec remove(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove(%Config{} = config, plugin, opts \\ []) when is_binary(plugin),
    do: run(config, :remove, plugin, opts)

  # --- Marketplaces ---

  @doc """
  Add a local or Git marketplace source.

  ## Options

    * `:ref` - Git ref to check out (`--ref`)
    * `:sparse` - sparse-checkout path, or a list of them (`--sparse`)
  """
  @spec marketplace_add(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def marketplace_add(%Config{} = config, source, opts \\ []) when is_binary(source),
    do: run(config, :marketplace_add, source, opts)

  @doc "List the marketplaces codex is considering and their roots."
  @spec marketplace_list(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def marketplace_list(%Config{} = config, opts \\ []),
    do: run(config, :marketplace_list, nil, opts)

  @doc "Refresh Git marketplace snapshots: all of them, or the one named `name`."
  @spec marketplace_upgrade(Config.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def marketplace_upgrade(%Config{} = config, name \\ nil, opts \\ [])
      when is_binary(name) or is_nil(name),
      do: run(config, :marketplace_upgrade, name, opts)

  @doc "Remove a configured marketplace source by name."
  @spec marketplace_remove(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def marketplace_remove(%Config{} = config, name, opts \\ []) when is_binary(name),
    do: run(config, :marketplace_remove, name, opts)

  # --- Arg building ---

  @doc """
  Build the command for `action`, validating `opts`.

  Raises `ArgumentError` on an option `action` does not take.
  """
  @spec new(action(), String.t() | nil, keyword()) :: t()
  def new(action, target, opts \\ []) do
    validate!(opts, allowed(action) ++ @common)
    %__MODULE__{action: action, target: target, opts: opts}
  end

  @impl true
  def args(%__MODULE__{action: action, target: target, opts: opts}) do
    subcommand(action) ++
      ["--json"] ++
      Enum.flat_map(opts, &option/1) ++
      if(target, do: ["--", target], else: [])
  end

  @impl true
  def parse_output(stdout, 0), do: decode(stdout)
  def parse_output(stdout, exit_code), do: {:error, {:exit, exit_code, stdout}}

  defp run(config, action, target, opts) do
    Command.run(__MODULE__, new(action, target, opts), config)
  end

  defp subcommand(:list), do: ["plugin", "list"]
  defp subcommand(:add), do: ["plugin", "add"]
  defp subcommand(:remove), do: ["plugin", "remove"]
  defp subcommand(:marketplace_add), do: ["plugin", "marketplace", "add"]
  defp subcommand(:marketplace_list), do: ["plugin", "marketplace", "list"]
  defp subcommand(:marketplace_upgrade), do: ["plugin", "marketplace", "upgrade"]
  defp subcommand(:marketplace_remove), do: ["plugin", "marketplace", "remove"]

  defp allowed(:list), do: [:marketplace, :available]
  defp allowed(action) when action in [:add, :remove], do: [:marketplace]
  defp allowed(:marketplace_add), do: [:ref, :sparse]
  defp allowed(_action), do: []

  defp option({:available, true}), do: ["--available"]
  defp option({:available, false}), do: []
  defp option({:marketplace, value}), do: ["--marketplace=" <> value]
  defp option({:ref, value}), do: ["--ref=" <> value]
  defp option({:sparse, values}), do: Enum.map(List.wrap(values), &("--sparse=" <> &1))
  defp option({:config, values}), do: Enum.flat_map(List.wrap(values), &["-c", &1])
  defp option({:enable, values}), do: Enum.map(List.wrap(values), &("--enable=" <> &1))
  defp option({:disable, values}), do: Enum.map(List.wrap(values), &("--disable=" <> &1))

  defp validate!(opts, allowed) do
    Enum.each(opts, fn
      {key, value} when is_atom(key) ->
        unless key in allowed, do: raise(ArgumentError, "unknown option #{inspect(key)}")
        check_value!(key, value)

      other ->
        raise ArgumentError, "expected a keyword option, got: #{inspect(other)}"
    end)
  end

  defp check_value!(:available, value) when is_boolean(value), do: :ok

  defp check_value!(key, value) when key in [:marketplace, :ref] and is_binary(value),
    do: :ok

  defp check_value!(key, value) when key in [:sparse | @common] do
    if is_binary(value) or (is_list(value) and Enum.all?(value, &is_binary/1)),
      do: :ok,
      else: bad_value!(key, value)
  end

  defp check_value!(key, value), do: bad_value!(key, value)

  defp bad_value!(key, value),
    do: raise(ArgumentError, "invalid value for option #{inspect(key)}: #{inspect(value)}")

  # The runner merges stderr into stdout, so a warning line can precede the
  # JSON document. Decode from the first line that opens a JSON value.
  defp decode(output) do
    case Jason.decode(output) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        output
        |> String.split("\n")
        |> Enum.drop_while(&(not String.starts_with?(&1, ["{", "["])))
        |> Enum.join("\n")
        |> Jason.decode()
        |> case do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, {:json, output}}
        end
    end
  end
end
