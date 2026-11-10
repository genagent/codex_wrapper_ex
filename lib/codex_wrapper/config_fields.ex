defmodule CodexWrapper.ConfigFields do
  @moduledoc false

  # Typed config fields emitted as `-c key=value`, shared by Exec,
  # ExecResume, ExecFork and Review. Each builder keeps them in one
  # `config_fields` map of config key to rendered TOML value, so the structs
  # do not grow by a field per setting.
  #
  # Accepted values were checked with `--strict-config` on codex-cli
  # 0.149.0, 0.164.0 and 0.165.0.

  @reasoning_summaries [:auto, :concise, :detailed, :none]
  @verbosities [:low, :medium, :high]
  @approvals_reviewers [:user, :auto_review, :guardian_subagent]
  @rollout_keys [
    :limit_tokens,
    :reminder_at_remaining_tokens,
    :sampling_token_weight,
    :prefill_token_weight
  ]

  @type reasoning_summary :: :auto | :concise | :detailed | :none
  @type verbosity :: :low | :medium | :high
  @type approvals_reviewer :: :user | :auto_review | :guardian_subagent
  @type rollout_budget :: [
          limit_tokens: pos_integer(),
          reminder_at_remaining_tokens: [pos_integer()],
          sampling_token_weight: number(),
          prefill_token_weight: number()
        ]

  @doc false
  @spec put(map(), atom(), term()) :: map()
  def put(fields, :reasoning_effort, effort) when is_binary(effort) and effort != "",
    do: Map.put(fields, "model_reasoning_effort", quote_string(effort))

  def put(_fields, :reasoning_effort, effort),
    do: bad!("reasoning_effort", effort, "a non-empty string")

  def put(fields, :reasoning_summary, value) when value in @reasoning_summaries,
    do: Map.put(fields, "model_reasoning_summary", quote_string(value))

  def put(_fields, :reasoning_summary, value),
    do: bad!("reasoning_summary", value, "one of #{inspect(@reasoning_summaries)}")

  def put(fields, :verbosity, value) when value in @verbosities,
    do: Map.put(fields, "model_verbosity", quote_string(value))

  def put(_fields, :verbosity, value),
    do: bad!("verbosity", value, "one of #{inspect(@verbosities)}")

  def put(fields, :approvals_reviewer, value) when value in @approvals_reviewers,
    do: Map.put(fields, "approvals_reviewer", quote_string(value))

  def put(_fields, :approvals_reviewer, value),
    do: bad!("approvals_reviewer", value, "one of #{inspect(@approvals_reviewers)}")

  def put(fields, :rollout_budget, opts),
    do: Map.put(fields, "features.rollout_budget", rollout_budget(opts))

  @doc false
  # `key=value` overrides in a stable order.
  @spec overrides(map()) :: [String.t()]
  def overrides(fields) do
    fields |> Enum.sort() |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
  end

  defp rollout_budget(opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: bad!("rollout_budget", opts, "a keyword list")

    case Keyword.keys(opts) -- @rollout_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown rollout_budget option(s): #{inspect(unknown)}"
    end

    entries =
      [
        "enabled=true",
        "limit_tokens=#{limit_tokens!(opts[:limit_tokens])}",
        "reminder_at_remaining_tokens=[#{Enum.join(reminders!(opts[:reminder_at_remaining_tokens]), ",")}]"
      ] ++
        for key <- [:sampling_token_weight, :prefill_token_weight], Keyword.has_key?(opts, key) do
          "#{key}=#{weight!(key, Keyword.fetch!(opts, key))}"
        end

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp rollout_budget(opts), do: bad!("rollout_budget", opts, "a keyword list")

  defp limit_tokens!(limit) when is_integer(limit) and limit > 0, do: limit

  defp limit_tokens!(limit),
    do: bad!("rollout_budget :limit_tokens", limit, "a positive integer")

  defp reminders!(reminders) do
    if is_list(reminders) and reminders != [] and
         Enum.all?(reminders, &(is_integer(&1) and &1 > 0)),
       do: reminders,
       else:
         bad!(
           "rollout_budget :reminder_at_remaining_tokens",
           reminders,
           "a non-empty list of positive integers"
         )
  end

  defp weight!(_key, weight) when is_number(weight) and weight > 0,
    do: :erlang.float_to_binary(weight / 1, [:short])

  defp weight!(key, weight),
    do: bad!("rollout_budget #{inspect(key)}", weight, "a positive number")

  # A TOML basic string. Effort is caller text, so escape it.
  defp quote_string(value) when is_atom(value), do: quote_string(Atom.to_string(value))
  defp quote_string(value), do: Jason.encode!(value)

  defp bad!(name, value, expected),
    do: raise(ArgumentError, "#{name} expects #{expected}, got: #{inspect(value)}")
end
