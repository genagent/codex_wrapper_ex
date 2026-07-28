defmodule CodexWrapper.Commands.Archive do
  @moduledoc """
  Session lifecycle commands -- archive, unarchive, and delete a saved session.

  Wraps `codex archive <session>`, `codex unarchive <session>`, and
  `codex delete <session>`. Each takes a session id (UUID) or a session
  name; the CLI prefers the UUID interpretation when the argument parses
  as one.

  ## Usage

      config = CodexWrapper.Config.new()

      {:ok, _} = CodexWrapper.Commands.Archive.archive(config, "abc-123")
      {:ok, _} = CodexWrapper.Commands.Archive.unarchive(config, "abc-123")

  ## Deleting

  `codex delete` permanently destroys the saved session; there is no
  undo, and `unarchive/2` cannot bring it back. So `delete/3` will not
  run unless the caller passes `confirm: true`:

      CodexWrapper.Commands.Archive.delete(config, "abc-123")
      #=> {:error, :confirmation_required}

      CodexWrapper.Commands.Archive.delete(config, "abc-123", confirm: true)
      #=> {:ok, ""}

  Without the flag the CLI is never invoked, so a delete reached by
  mistake -- a wrong branch, a stale variable -- costs nothing. Archiving
  is the reversible option and should be the default reach.
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config}

  @type action :: :archive | :unarchive | :delete

  @type t :: %__MODULE__{
          action: action(),
          session: String.t()
        }

  defstruct [:action, :session]

  @actions [:archive, :unarchive, :delete]

  # --- Constructor ---

  @doc """
  Build a lifecycle command for the given action and session.

  The session is an id (UUID) or a session name.
  """
  @spec new(action(), String.t()) :: t()
  def new(action, session) when action in @actions and is_binary(session) do
    %__MODULE__{action: action, session: session}
  end

  # --- Execution ---

  @doc """
  Archive a saved session. Reversible with `unarchive/2`.
  """
  @spec archive(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def archive(%Config{} = config, session) when is_binary(session) do
    Command.run(__MODULE__, new(:archive, session), config)
  end

  @doc """
  Unarchive a previously archived session.
  """
  @spec unarchive(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def unarchive(%Config{} = config, session) when is_binary(session) do
    Command.run(__MODULE__, new(:unarchive, session), config)
  end

  @doc """
  Permanently delete a saved session.

  Requires `confirm: true`. Without it this returns
  `{:error, :confirmation_required}` and the CLI is not invoked. See the
  module docs for why.

  ## Options

    * `:confirm` - must be `true` for the delete to run
  """
  @spec delete(Config.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :confirmation_required | term()}
  def delete(%Config{} = config, session, opts \\ []) when is_binary(session) do
    if Keyword.get(opts, :confirm) == true do
      Command.run(__MODULE__, new(:delete, session), config)
    else
      {:error, :confirmation_required}
    end
  end

  # --- Arg building ---

  @doc """
  Build the argument list for an action and session.
  """
  @spec build_args(action(), String.t()) :: [String.t()]
  def build_args(action, session) when action in @actions and is_binary(session) do
    args(new(action, session))
  end

  @impl true
  def args(%__MODULE__{action: action, session: session}) do
    [Atom.to_string(action), session]
  end

  @impl true
  def parse_output(stdout, 0), do: {:ok, String.trim(stdout)}
  def parse_output(stdout, exit_code), do: {:error, {:exit, exit_code, stdout}}
end
