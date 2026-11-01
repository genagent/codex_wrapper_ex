defmodule CodexWrapper.Argv do
  @moduledoc false

  # Leave room for interpreter paths, alignment and shell-added environment
  # entries. This deliberately rejects inputs very close to the OS ceiling.
  @reserve_bytes 4_096
  @pointer_bytes 8

  @type size_error :: {:argument_list_too_long, map()}

  @spec validate(String.t(), [String.t()], keyword()) ::
          :ok | {:error, size_error() | {:invalid_argument, non_neg_integer()}}
  def validate(binary, args, opts) do
    validate(binary, args, opts, limits())
  end

  @doc false
  def validate(binary, args, opts, limits) do
    argv = [binary | args]
    env = environment(opts)

    with :ok <- valid_arguments(argv),
         :ok <- validate_strings(argv, :argument, limits.string),
         :ok <- validate_strings(env, :environment, limits.string) do
      bytes =
        string_bytes(argv) + string_bytes(env) +
          @pointer_bytes * (length(argv) + length(env) + 2) +
          byte_size(binary) + 1 + @reserve_bytes

      if bytes > limits.total,
        do: too_long(:total, bytes, limits.total),
        else: :ok
    end
  end

  # Linux's aggregate limit depends on RLIMIT_STACK, so query it at execution
  # time. Linux also limits every individual argument/environment string to
  # 32 pages, including its terminating NUL. macOS has no separate string cap.
  @doc false
  def limits do
    string =
      case :os.type() do
        {:unix, :linux} -> 32 * getconf("PAGESIZE", 4_096)
        _ -> nil
      end

    %{total: getconf("ARG_MAX", 32_768), string: string}
  end

  defp environment(opts) do
    base = if opts[:env_mode] == :replace, do: %{}, else: System.get_env()

    opts
    |> Keyword.get(:env, [])
    |> CodexWrapper.Config.validate_env!()
    |> Enum.reduce(base, fn
      {key, false}, env -> Map.delete(env, key)
      {key, value}, env -> Map.put(env, key, value)
    end)
    |> Enum.map(fn {key, value} -> key <> "=" <> value end)
  end

  defp valid_arguments(argv) do
    case Enum.find_index(argv, &String.contains?(&1, <<0>>)) do
      nil -> :ok
      index -> {:error, {:invalid_argument, index}}
    end
  end

  defp validate_strings(_values, _kind, nil), do: :ok

  defp validate_strings(values, kind, limit) do
    case Enum.find(values, &(byte_size(&1) + 1 > limit)) do
      nil -> :ok
      value -> too_long(kind, byte_size(value) + 1, limit)
    end
  end

  defp string_bytes(values), do: Enum.reduce(values, 0, &(byte_size(&1) + 1 + &2))

  defp too_long(kind, bytes, limit),
    do: {:error, {:argument_list_too_long, %{kind: kind, bytes: bytes, limit: limit}}}

  defp getconf(name, fallback) do
    case System.cmd("/usr/bin/getconf", [name], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {value, ""} when value > 0 -> value
          _ -> fallback
        end

      _ ->
        fallback
    end
  rescue
    ErlangError -> fallback
  end
end
