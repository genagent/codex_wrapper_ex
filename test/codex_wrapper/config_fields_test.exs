defmodule CodexWrapper.ConfigFieldsTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Exec, ExecFork, ExecResume, Options, Review}

  @budget limit_tokens: 100_000, reminder_at_remaining_tokens: [50_000, 10_000]

  defp typed(command, module) do
    command
    |> module.reasoning_effort("high")
    |> module.reasoning_summary(:concise)
    |> module.verbosity(:low)
    |> module.approvals_reviewer(:auto_review)
    |> module.rollout_budget(@budget)
  end

  @expected [
    ~s(approvals_reviewer="auto_review"),
    "features.rollout_budget={enabled=true,limit_tokens=100000,reminder_at_remaining_tokens=[50000,10000]}",
    ~s(model_reasoning_effort="high"),
    ~s(model_reasoning_summary="concise"),
    ~s(model_verbosity="low")
  ]

  defp overrides(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["-c", kv] -> [kv]
      _ -> []
    end)
  end

  test "every builder emits the typed fields as -c overrides" do
    for {module, command} <- [
          {Exec, Exec.new("p")},
          {ExecResume, ExecResume.new() |> ExecResume.last()},
          {ExecFork, ExecFork.new("thread-A")},
          {Review, Review.new() |> Review.uncommitted()}
        ] do
      assert command |> typed(module) |> module.args() |> overrides() == @expected,
             inspect(module)
    end
  end

  test "typed fields follow config/2 entries, so they win for the same key" do
    args =
      Exec.new("p")
      |> Exec.config(~s(model_verbosity="high"))
      |> Exec.verbosity(:low)
      |> Exec.approval_policy(:never)
      |> Exec.args()

    assert overrides(args) == [
             ~s(model_verbosity="high"),
             ~s(model_verbosity="low"),
             ~s(approval_policy="never")
           ]
  end

  test "a later call replaces an earlier one" do
    args = Exec.new("p") |> Exec.verbosity(:low) |> Exec.verbosity(:high) |> Exec.args()
    assert overrides(args) == [~s(model_verbosity="high")]
  end

  test "reasoning effort is quoted as a TOML string" do
    args = Exec.new("p") |> Exec.reasoning_effort(~s(a"b)) |> Exec.args()
    assert overrides(args) == [~s(model_reasoning_effort="a\\"b")]
  end

  test "rollout budget weights are rendered as floats" do
    args =
      Exec.new("p")
      |> Exec.rollout_budget(@budget ++ [sampling_token_weight: 1.5, prefill_token_weight: 2])
      |> Exec.args()

    assert overrides(args) == [
             "features.rollout_budget={enabled=true,limit_tokens=100000," <>
               "reminder_at_remaining_tokens=[50000,10000],sampling_token_weight=1.5," <>
               "prefill_token_weight=2.0}"
           ]
  end

  test "invalid values raise before spawning" do
    e = Exec.new("p")

    for {fun, value} <- [
          reasoning_effort: "",
          reasoning_effort: :high,
          reasoning_summary: :brief,
          verbosity: "low",
          approvals_reviewer: :anyone,
          rollout_budget: [limit_tokens: 10],
          rollout_budget: [reminder_at_remaining_tokens: [1]],
          rollout_budget: [limit_tokens: 0, reminder_at_remaining_tokens: [1]],
          rollout_budget: [limit_tokens: 10, reminder_at_remaining_tokens: []],
          rollout_budget: [limit_tokens: 10, reminder_at_remaining_tokens: [-1]],
          rollout_budget: [
            limit_tokens: 10,
            reminder_at_remaining_tokens: [1],
            sampling_token_weight: 0
          ],
          rollout_budget: [limit_tokens: 10, reminder_at_remaining_tokens: [1], bogus: 1],
          rollout_budget: %{limit_tokens: 10}
        ] do
      assert_raise ArgumentError, fn -> apply(Exec, fun, [e, value]) end
    end
  end

  test "keyword options reach every entry point" do
    opts = [reasoning_effort: "low", verbosity: :medium, rollout_budget: @budget]

    for args <- [
          Options.exec("p", opts) |> Exec.args(),
          Options.exec_resume("thread-A", "p", opts) |> ExecResume.args(),
          Options.review([uncommitted: true] ++ opts) |> Review.args()
        ] do
      assert ~s(model_reasoning_effort="low") in args
      assert ~s(model_verbosity="medium") in args
      assert Enum.any?(args, &String.starts_with?(&1, "features.rollout_budget={"))
    end
  end
end
