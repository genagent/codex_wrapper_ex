defmodule CodexWrapper.StdinFile do
  @moduledoc false

  @create_attempts 5

  # File.mkdir/open cannot set creation permissions. Restrict only this shell's
  # umask, leaving the VM and concurrent callers untouched. No prompt bytes are
  # passed to the shell. A successful mkdir establishes exclusive ownership.
  @create_script """
  umask 077
  /bin/mkdir "$1" || exit 1
  command : > "$1/prompt" || { /bin/rmdir "$1"; exit 2; }
  """

  @doc false
  def with_file(opts, fun) do
    with_file(opts, fun, &random_directory/0)
  end

  # The internal directory generator also lets collision tests use real
  # exclusive mkdir operations without changing process-global state.
  @doc false
  def with_file(opts, fun, next_directory) do
    with {:ok, path} <- create(Keyword.get(opts, :stdin), next_directory) do
      try do
        fun.(path)
      after
        cleanup(path)
      end
    end
  end

  @doc false
  def stream(opts, fun) do
    Stream.resource(
      fn -> create(Keyword.get(opts, :stdin)) end,
      &next/1,
      &close_stream/1
    )
    |> Stream.flat_map(fn
      {:ok, path} -> fun.(path)
      {:error, _} = error -> [error]
    end)
  end

  defp next({:ok, path} = input), do: {[input], {:done, path}}
  defp next({:error, _} = error), do: {[error], {:done, nil}}
  defp next({:done, _} = state), do: {:halt, state}

  defp close_stream({:error, _}), do: :ok
  defp close_stream({_state, path}), do: cleanup(path)

  defp create(input), do: create(input, &random_directory/0)

  defp create(nil, _next_directory), do: {:ok, nil}

  defp create(input, next_directory) when is_binary(input) do
    create(input, next_directory, @create_attempts)
  rescue
    error in ErlangError -> {:error, {:stdin_file, error.original}}
    error in File.Error -> {:error, {:stdin_file, error.reason}}
  end

  defp create(_input, _next_directory, 0), do: {:error, {:stdin_file, {:create, 1}}}

  defp create(input, next_directory, attempts) do
    directory = next_directory.()

    case System.cmd("/bin/sh", ["-c", @create_script, "codex-wrapper-stdin", directory],
           stderr_to_stdout: true
         ) do
      {_, 0} -> write_input(Path.join(directory, "prompt"), input)
      {_, 1} -> create(input, next_directory, attempts - 1)
      {_, status} -> {:error, {:stdin_file, {:create, status}}}
    end
  end

  defp random_directory do
    # References are only unique within one BEAM instance. Random bytes keep
    # independently started VMs from choosing the same names in a shared tmpdir.
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    Path.join(System.tmp_dir!(), "codex-wrapper-stdin-" <> suffix)
  end

  defp write_input(path, input) do
    case File.write(path, input, [:binary]) do
      :ok ->
        {:ok, path}

      {:error, reason} ->
        cleanup(path)
        {:error, {:stdin_file, {:write, reason}}}
    end
  end

  defp cleanup(nil), do: :ok

  defp cleanup(path) do
    File.rm(path)
    File.rmdir(Path.dirname(path))
    :ok
  end
end
