defmodule CodexWrapper.Retry do
  @moduledoc """
  Retry policy with exponential backoff for exec execution.

  ## Usage

      config = CodexWrapper.Config.new()
      exec = CodexWrapper.Exec.new("fix the bug")

      # Retry up to 3 times with exponential backoff
      {:ok, result} = CodexWrapper.Retry.execute(exec, config,
        max_retries: 3,
        base_delay_ms: 1_000,
        max_delay_ms: 30_000
      )

      # With custom retry predicate
      {:ok, result} = CodexWrapper.Retry.execute(exec, config,
        max_retries: 5,
        retry_on: fn
          {:error, {:timeout, _}} -> true
          {:error, {:system_cmd, _}} -> true
          _ -> false
        end
      )

  ## Failed runs

  A run that exits nonzero returns `{:ok, %CodexWrapper.Result{success: false}}`
  from `CodexWrapper.Exec.execute/2`. `:retry_on` receives that tuple as well
  as `{:error, reason}` (#152). The default predicate does not retry failed
  runs: each attempt re-sends the prompt as a new `codex exec`, and the tool
  commands a failed attempt ran (file edits, shell commands) are not undone,
  so a retry can repeat them. When retries are exhausted or `:retry_on`
  returns `false`, the failed run is returned as is.

  The wrapper does not classify capacity or rate-limit failures. codex-cli
  0.165.0 does not pass the provider's status or error code through in
  `--json` output: a 429, 503 or 529 appears only inside codex's own
  message text (for example `exceeded retry limit, last status: 429 Too
  Many Requests`), which can change between CLI versions. A caller that
  wants to retry those can inspect the failed turn itself:

      retry_on = fn
        {:ok, %CodexWrapper.Result{success: false} = result} ->
          case CodexWrapper.Turn.from_result(result).error do
            %{"message" => message} when is_binary(message) ->
              message =~ ~r/status (429|503|529)\\b/

            _ ->
              false
          end

        _ ->
          false
      end
  """

  alias CodexWrapper.{Config, Exec, Result}

  @type opts :: [
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          multiplier: number(),
          jitter: boolean(),
          retry_on: (term() -> boolean())
        ]

  @default_max_retries 3
  @default_base_delay_ms 1_000
  @default_max_delay_ms 30_000
  @default_multiplier 2

  @doc """
  Execute an exec command with retry logic.

  ## Options

    * `:max_retries` - Maximum number of retry attempts (default: 3)
    * `:base_delay_ms` - Initial delay between retries in ms (default: 1000)
    * `:max_delay_ms` - Maximum delay cap in ms (default: 30000)
    * `:multiplier` - Backoff multiplier (default: 2)
    * `:jitter` - Add random jitter to delays (default: true)
    * `:retry_on` - Function that receives `{:error, reason}`, or
      `{:ok, %CodexWrapper.Result{success: false}}` for a run that exited
      nonzero, and returns whether to retry. Defaults to retrying on
      timeouts and system cmd errors only; see "Failed runs".
  """
  @spec execute(Exec.t(), Config.t(), opts()) :: {:ok, Result.t()} | {:error, term()}
  def execute(%Exec{} = exec, %Config{} = config, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max_delay = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    multiplier = Keyword.get(opts, :multiplier, @default_multiplier)
    jitter? = Keyword.get(opts, :jitter, true)
    retry_on = Keyword.get(opts, :retry_on, &default_retry_on/1)

    retry_opts = %{
      max_retries: max_retries,
      base_delay: base_delay,
      max_delay: max_delay,
      multiplier: multiplier,
      jitter?: jitter?,
      retry_on: retry_on
    }

    do_execute(exec, config, 0, retry_opts)
  end

  defp do_execute(exec, config, attempt, opts) do
    %{
      max_retries: max_retries,
      base_delay: base_delay,
      max_delay: max_delay,
      multiplier: multiplier,
      jitter?: jitter?,
      retry_on: retry_on
    } = opts

    case Exec.execute(exec, config) do
      {:ok, %Result{success: true}} = success ->
        success

      failure ->
        if attempt < max_retries and retry_on.(failure) do
          delay = compute_delay(attempt, base_delay, max_delay, multiplier, jitter?)
          Process.sleep(delay)
          do_execute(exec, config, attempt + 1, opts)
        else
          failure
        end
    end
  end

  @doc """
  Compute the delay for a given attempt number.
  """
  @spec compute_delay(non_neg_integer(), pos_integer(), pos_integer(), number(), boolean()) ::
          non_neg_integer()
  def compute_delay(attempt, base_delay, max_delay, multiplier, jitter?) do
    delay = round(base_delay * :math.pow(multiplier, attempt))
    delay = min(delay, max_delay)

    if jitter? do
      :rand.uniform(delay + 1) - 1
    else
      delay
    end
  end

  defp default_retry_on({:error, {:timeout, _}}), do: true
  defp default_retry_on({:error, {:system_cmd, _}}), do: true
  defp default_retry_on(_), do: false
end
