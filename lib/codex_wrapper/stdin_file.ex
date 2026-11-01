defmodule CodexWrapper.StdinFile do
  @moduledoc false

  # File.mkdir/open cannot set creation permissions. Restrict only this shell's
  # umask, leaving the VM and concurrent callers untouched. No prompt bytes are
  # passed to the shell. A successful mkdir establishes exclusive ownership.
  @create_script """
  umask 077
  /bin/mkdir "$1" || exit 1
  : > "$1/prompt" || { /bin/rmdir "$1"; exit 2; }
  """

  @doc false
  def with_file(opts, fun) do
    with {:ok, path} <- create(Keyword.get(opts, :stdin)) do
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

  defp create(nil), do: {:ok, nil}

  defp create(input) when is_binary(input) do
    suffix = Base.url_encode64(:erlang.term_to_binary(make_ref()), padding: false)
    directory = Path.join(System.tmp_dir!(), "codex-wrapper-stdin-" <> suffix)

    case System.cmd("/bin/sh", ["-c", @create_script, "codex-wrapper-stdin", directory],
           stderr_to_stdout: true
         ) do
      {_, 0} -> write_input(Path.join(directory, "prompt"), input)
      {_, status} -> {:error, {:stdin_file, {:create, status}}}
    end
  rescue
    error in ErlangError -> {:error, {:stdin_file, error.original}}
    error in File.Error -> {:error, {:stdin_file, error.reason}}
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
