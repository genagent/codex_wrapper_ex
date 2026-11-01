defmodule CodexWrapper.ChildEnv do
  @moduledoc """
  Removes the host release's boot environment from child processes.

  Helpers accept a parent environment map, such as `System.get_env/0`, without
  modifying the VM's environment. Removals use `false`, as accepted by the
  wrapper's runners. This prevents accidental inheritance, not access to release
  files by a child running as the same OS user.
  """

  @type parent_env :: %{String.t() => String.t()}
  @type entries :: [{String.t(), String.t() | false}]

  @doc """
  Return release environment removals and a cleaned PATH.

  Does nothing unless `RELEASE_ROOT` is set in `parent`. Removes all inherited
  `RELEASE_*` names, `BINDIR`, and `ROOTDIR`. PATH filtering removes complete
  entries equal to `BINDIR`, either root's `bin`, or either root's direct
  `erts-<version>/bin`. Other entries retain their order, including duplicates
  and empty entries. An absent PATH stays absent.
  """
  @spec release_scrub(parent_env()) :: entries()
  def release_scrub(parent) do
    if release?(parent) do
      removals =
        parent
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, "RELEASE_"))
        |> Kernel.++(["BINDIR", "ROOTDIR"])
        |> Enum.sort()
        |> Enum.map(&{&1, false})

      case parent["PATH"] do
        nil -> removals
        path -> removals ++ [{"PATH", scrub_path(path, parent)}]
      end
    else
      []
    end
  end

  @doc """
  Apply caller overrides after the release scrub using a supplied parent map.

  Explicit values may restore removed names. Explicit PATH values still have
  the parent's release entries removed; `nil` or `false` leaves PATH unset.
  Duplicate names retain last-entry-wins semantics. With `:inherit`, or without
  `RELEASE_ROOT`, returns only the validated overrides.
  """
  @spec normalize(Enumerable.t(), parent_env(), :scrub | :inherit) :: entries()
  def normalize(env, parent, mode \\ :scrub) when mode in [:scrub, :inherit] do
    env = CodexWrapper.Config.validate_env!(env)

    if mode == :scrub and release?(parent) do
      release_scrub(parent) ++
        Enum.map(env, fn
          {"PATH", value} when is_binary(value) -> {"PATH", scrub_path(value, parent)}
          entry -> entry
        end)
    else
      env
    end
  end

  defp release?(parent), do: not is_nil(parent["RELEASE_ROOT"])

  defp scrub_path(path, parent) do
    roots = Enum.filter([parent["ROOTDIR"], parent["RELEASE_ROOT"]], &nonempty?/1)
    bins = Enum.filter([parent["BINDIR"] | Enum.map(roots, &Path.join(&1, "bin"))], &nonempty?/1)

    path
    |> String.split(":")
    |> Enum.reject(fn entry ->
      entry in bins or Enum.any?(roots, &erts_bin?(entry, &1))
    end)
    |> Enum.join(":")
  end

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp erts_bin?(entry, root) do
    prefix = Path.join(root, "erts-")

    if String.starts_with?(entry, prefix) do
      case entry |> String.replace_prefix(prefix, "") |> String.split("/") do
        [version, "bin"] when version != "" -> true
        _ -> false
      end
    else
      false
    end
  end
end
