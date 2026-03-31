defmodule CodexWrapper.IEx do
  @moduledoc """
  Interactive helpers for conversational use in IEx.

  Provides a minimal, REPL-friendly interface that manages session state
  implicitly so you can just talk to Codex.

  ## Usage

      iex> import CodexWrapper.IEx

      iex> chat("explain this codebase", working_dir: ".")
      # => prints response

      iex> say("now add tests for the retry module")
      # => continues the conversation

      iex> cost()
      # => $0.00 across 2 turns

      iex> history()
      # => prints conversation

      iex> reset()
      # => starts fresh

  ## Configuration

  Pass options to `chat/2` to configure the session. These persist for
  subsequent `say/2` calls:

      chat("hello", model: "o3", working_dir: "/my/project")

  Override per-turn with `say/2`:

      say("do something different", model: "o4-mini")
  """

  alias CodexWrapper.{Config, Result, Session}

  @session_key :codex_wrapper_iex_session
  @config_key :codex_wrapper_iex_config

  @doc """
  Start a new conversation. Prints the response.

  Accepts all options from `CodexWrapper.exec/2` -- config options
  (`:working_dir`, `:binary`, `:env`, `:timeout`, `:verbose`)
  and exec options (`:model`, `:sandbox`, `:approval_policy`, etc.).
  """
  def chat(prompt, opts \\ []) do
    {config_opts, exec_opts} = split_opts(opts)
    config = Config.new(config_opts)
    session = Session.new(config, exec_opts)

    Process.put(@config_key, config)

    do_send(session, prompt, [])
  end

  @doc """
  Continue the current conversation. Prints the response.

  Accepts per-turn exec option overrides.
  """
  def say(prompt, opts \\ []) do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session. Start one with chat/2.\e[0m")
        :no_session

      session ->
        do_send(session, prompt, opts)
    end
  end

  @doc """
  Show total cost and turn count for the current session.
  """
  def cost do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session.\e[0m")
        :no_session

      session ->
        total = Session.total_cost(session)
        turns = Session.turn_count(session)
        IO.puts("\e[33m$#{Float.round(total, 4)} across #{turns} turn#{plural(turns)}\e[0m")
        total
    end
  end

  @doc """
  Print the conversation history.
  """
  def history do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session.\e[0m")
        :no_session

      session ->
        session |> Session.turns() |> print_history()
        :ok
    end
  end

  @doc """
  Reset the session (start fresh on next `chat/2`).
  """
  def reset do
    Process.delete(@session_key)
    Process.delete(@config_key)
    IO.puts("\e[33mSession cleared.\e[0m")
    :ok
  end

  @doc """
  Get the session ID (for resuming later).
  """
  def session_id do
    case Process.get(@session_key) do
      nil -> nil
      session -> Session.session_id(session)
    end
  end

  @doc """
  Resume a previous session by ID.

  Uses the same config as the last `chat/2` call, or pass new options.
  """
  def resume(sid, opts \\ []) do
    {config_opts, exec_opts} = split_opts(opts)

    config =
      if config_opts == [] do
        Process.get(@config_key) || Config.new()
      else
        Config.new(config_opts)
      end

    session = Session.resume(config, sid, exec_opts)
    Process.put(@session_key, session)
    Process.put(@config_key, config)
    IO.puts("\e[33mResumed session #{sid}\e[0m")
    :ok
  end

  @doc """
  Get the last result struct (for programmatic access).
  """
  def last do
    case Process.get(@session_key) do
      nil -> nil
      session -> Session.last_result(session)
    end
  end

  # --- Private ---

  defp print_history([]) do
    IO.puts("\e[33mNo turns yet.\e[0m")
  end

  defp print_history(turns) do
    turns
    |> Enum.with_index(1)
    |> Enum.each(&print_turn/1)
  end

  defp print_turn({result, i}) do
    IO.puts("\e[36m--- Turn #{i} ---\e[0m")
    IO.puts(result.stdout)
    IO.puts("")
  end

  defp do_send(session, prompt, opts) do
    IO.puts("\e[33m...\e[0m")

    case Session.send(session, prompt, opts) do
      {:ok, new_session, result} ->
        Process.put(@session_key, new_session)
        print_result(result, new_session)
        :ok

      {:error, reason} ->
        IO.puts("\e[31mError: #{inspect(reason)}\e[0m")
        {:error, reason}
    end
  end

  defp print_result(%Result{} = result, session) do
    IO.puts("")
    IO.puts(result.stdout)
    IO.puts("")

    total = Session.total_cost(session)
    turns = Session.turn_count(session)

    IO.puts(
      "\e[33m($#{Float.round(total, 4)} total, #{turns} turn#{plural(turns)})\e[0m"
    )
  end

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose]

  defp split_opts(opts) do
    Enum.split_with(opts, fn {k, _v} -> k in @config_keys end)
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
