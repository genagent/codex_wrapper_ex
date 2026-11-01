defmodule CodexWrapper.Options do
  @moduledoc false

  # Keyword options to builder calls, shared by `CodexWrapper.exec/2`,
  # `CodexWrapper.review/1` and `CodexWrapper.Session`. Every option either
  # maps to a builder call or raises: an option that reaches no flag would
  # run codex with settings the caller did not ask for.

  alias CodexWrapper.{Exec, ExecResume, Review}

  @sandbox_modes [:read_only, :workspace_write, :danger_full_access]
  @approval_policies [:untrusted, :on_request, :never]
  @search_modes [:cached, :indexed, :live, :disabled]
  @color_modes [:always, :never, :auto]
  @cyber_access_programs [:standard, :daybreak_blue, :daybreak_red]

  # Options `codex exec` accepts and `codex exec resume` rejects after the
  # subcommand. A session applies them on its first turn only.
  @first_turn_only [
    :profile,
    :cd,
    :add_dir,
    :color,
    :oss,
    :local_provider,
    :search,
    :approve_for_me,
    :worktree,
    :thread_source,
    :cyber_access_program
  ]

  @doc false
  @spec first_turn_only() :: [atom()]
  def first_turn_only, do: @first_turn_only

  @doc false
  @spec exec(String.t(), keyword()) :: Exec.t()
  def exec(prompt, opts) do
    Enum.reduce(opts, Exec.new(prompt), &exec_opt/2)
  end

  @doc false
  @spec review(keyword()) :: Review.t()
  def review(opts) do
    Enum.reduce(opts, Review.new(), &review_opt/2)
  end

  @doc false
  @spec exec_resume(String.t(), String.t(), keyword()) :: ExecResume.t()
  def exec_resume(session_id, prompt, opts) do
    resume = ExecResume.new() |> ExecResume.session_id(session_id) |> ExecResume.prompt(prompt)
    Enum.reduce(opts, resume, &exec_resume_opt/2)
  end

  # --- Exec ---

  defp exec_opt({:model, v}, e), do: Exec.model(e, string!(:model, v))
  defp exec_opt({:profile, v}, e), do: Exec.profile(e, string!(:profile, v))
  defp exec_opt({:sandbox, v}, e), do: Exec.sandbox(e, member!(:sandbox, v, @sandbox_modes))

  defp exec_opt({:approval_policy, v}, e), do: Exec.approval_policy(e, approval_policy!(v))

  defp exec_opt({:full_auto, v}, e), do: flag(e, :full_auto, v, &Exec.full_auto/1)

  defp exec_opt({:dangerously_bypass_approvals_and_sandbox, v}, e),
    do:
      flag(
        e,
        :dangerously_bypass_approvals_and_sandbox,
        v,
        &Exec.dangerously_bypass_approvals_and_sandbox/1
      )

  defp exec_opt({:dangerously_bypass_hook_trust, v}, e),
    do: flag(e, :dangerously_bypass_hook_trust, v, &Exec.dangerously_bypass_hook_trust/1)

  defp exec_opt({:strict_config, v}, e), do: flag(e, :strict_config, v, &Exec.strict_config/1)

  defp exec_opt({:ignore_user_config, v}, e),
    do: flag(e, :ignore_user_config, v, &Exec.ignore_user_config/1)

  defp exec_opt({:ignore_rules, v}, e), do: flag(e, :ignore_rules, v, &Exec.ignore_rules/1)
  defp exec_opt({:color, v}, e), do: Exec.color(e, member!(:color, v, @color_modes))
  defp exec_opt({:oss, v}, e), do: flag(e, :oss, v, &Exec.oss/1)

  defp exec_opt({:local_provider, v}, e),
    do: Exec.local_provider(e, string!(:local_provider, v))

  defp exec_opt({:cd, v}, e), do: Exec.cd(e, string!(:cd, v))

  defp exec_opt({:skip_git_repo_check, v}, e),
    do: flag(e, :skip_git_repo_check, v, &Exec.skip_git_repo_check/1)

  defp exec_opt({:add_dir, v}, e), do: each(e, :add_dir, v, &Exec.add_dir/2)
  defp exec_opt({:search, true}, e), do: Exec.search(e)
  defp exec_opt({:search, false}, e), do: e
  defp exec_opt({:search, v}, e), do: Exec.search(e, member!(:search, v, @search_modes))
  defp exec_opt({:ephemeral, v}, e), do: flag(e, :ephemeral, v, &Exec.ephemeral/1)
  defp exec_opt({:json, v}, e), do: flag(e, :json, v, &Exec.json/1)

  defp exec_opt({:output_schema, v}, e),
    do: Exec.output_schema(e, string!(:output_schema, v))

  defp exec_opt({:output_last_message, v}, e),
    do: Exec.output_last_message(e, string!(:output_last_message, v))

  defp exec_opt({:approve_for_me, v}, e), do: flag(e, :approve_for_me, v, &Exec.approve_for_me/1)
  defp exec_opt({:worktree, v}, e), do: flag(e, :worktree, v, &Exec.worktree/1)

  defp exec_opt({:thread_source, v}, e),
    do: Exec.thread_source(e, string!(:thread_source, v))

  defp exec_opt({:cyber_access_program, v}, e),
    do: Exec.cyber_access_program(e, member!(:cyber_access_program, v, @cyber_access_programs))

  defp exec_opt({:image, v}, e), do: each(e, :image, v, &Exec.image/2)
  defp exec_opt({:config, v}, e), do: each(e, :config, v, &Exec.config/2)
  defp exec_opt({:enable, v}, e), do: each(e, :enable, v, &Exec.enable/2)
  defp exec_opt({:disable, v}, e), do: each(e, :disable, v, &Exec.disable/2)
  defp exec_opt(other, _e), do: unknown!(other, "CodexWrapper.exec/2")

  # --- ExecResume ---

  defp exec_resume_opt({:model, v}, e), do: ExecResume.model(e, string!(:model, v))

  defp exec_resume_opt({:sandbox, v}, e),
    do: ExecResume.sandbox(e, member!(:sandbox, v, @sandbox_modes))

  defp exec_resume_opt({:approval_policy, v}, e),
    do: ExecResume.approval_policy(e, approval_policy!(v))

  defp exec_resume_opt({:full_auto, v}, e), do: flag(e, :full_auto, v, &ExecResume.full_auto/1)

  defp exec_resume_opt({:dangerously_bypass_approvals_and_sandbox, v}, e),
    do:
      flag(
        e,
        :dangerously_bypass_approvals_and_sandbox,
        v,
        &ExecResume.dangerously_bypass_approvals_and_sandbox/1
      )

  defp exec_resume_opt({:dangerously_bypass_hook_trust, v}, e),
    do: flag(e, :dangerously_bypass_hook_trust, v, &ExecResume.dangerously_bypass_hook_trust/1)

  defp exec_resume_opt({:strict_config, v}, e),
    do: flag(e, :strict_config, v, &ExecResume.strict_config/1)

  defp exec_resume_opt({:ignore_user_config, v}, e),
    do: flag(e, :ignore_user_config, v, &ExecResume.ignore_user_config/1)

  defp exec_resume_opt({:ignore_rules, v}, e),
    do: flag(e, :ignore_rules, v, &ExecResume.ignore_rules/1)

  defp exec_resume_opt({:skip_git_repo_check, v}, e),
    do: flag(e, :skip_git_repo_check, v, &ExecResume.skip_git_repo_check/1)

  defp exec_resume_opt({:ephemeral, v}, e), do: flag(e, :ephemeral, v, &ExecResume.ephemeral/1)
  defp exec_resume_opt({:json, v}, e), do: flag(e, :json, v, &ExecResume.json/1)

  defp exec_resume_opt({:output_schema, v}, e),
    do: ExecResume.output_schema(e, string!(:output_schema, v))

  defp exec_resume_opt({:output_last_message, v}, e),
    do: ExecResume.output_last_message(e, string!(:output_last_message, v))

  defp exec_resume_opt({:image, v}, e), do: each(e, :image, v, &ExecResume.image/2)
  defp exec_resume_opt({:config, v}, e), do: each(e, :config, v, &ExecResume.config/2)
  defp exec_resume_opt({:enable, v}, e), do: each(e, :enable, v, &ExecResume.enable/2)
  defp exec_resume_opt({:disable, v}, e), do: each(e, :disable, v, &ExecResume.disable/2)

  defp exec_resume_opt({key, _v}, _e) when key in @first_turn_only do
    raise ArgumentError,
          "option #{inspect(key)} applies to the first turn of a session only; " <>
            "codex exec resume does not accept it"
  end

  defp exec_resume_opt(other, _e), do: unknown!(other, "a resumed session turn")

  # --- Review ---

  defp review_opt({:prompt, v}, r), do: Review.prompt(r, string!(:prompt, v))
  defp review_opt({:uncommitted, v}, r), do: flag(r, :uncommitted, v, &Review.uncommitted/1)
  defp review_opt({:base, v}, r), do: Review.base(r, string!(:base, v))
  defp review_opt({:commit, v}, r), do: Review.commit(r, string!(:commit, v))
  defp review_opt({:title, v}, r), do: Review.title(r, string!(:title, v))
  defp review_opt({:model, v}, r), do: Review.model(r, string!(:model, v))
  defp review_opt({:sandbox, v}, r), do: Review.sandbox(r, member!(:sandbox, v, @sandbox_modes))
  defp review_opt({:full_auto, v}, r), do: flag(r, :full_auto, v, &Review.full_auto/1)

  defp review_opt({:dangerously_bypass_approvals_and_sandbox, v}, r),
    do:
      flag(
        r,
        :dangerously_bypass_approvals_and_sandbox,
        v,
        &Review.dangerously_bypass_approvals_and_sandbox/1
      )

  defp review_opt({:dangerously_bypass_hook_trust, v}, r),
    do: flag(r, :dangerously_bypass_hook_trust, v, &Review.dangerously_bypass_hook_trust/1)

  defp review_opt({:strict_config, v}, r), do: flag(r, :strict_config, v, &Review.strict_config/1)

  defp review_opt({:ignore_user_config, v}, r),
    do: flag(r, :ignore_user_config, v, &Review.ignore_user_config/1)

  defp review_opt({:ignore_rules, v}, r), do: flag(r, :ignore_rules, v, &Review.ignore_rules/1)

  defp review_opt({:skip_git_repo_check, v}, r),
    do: flag(r, :skip_git_repo_check, v, &Review.skip_git_repo_check/1)

  defp review_opt({:ephemeral, v}, r), do: flag(r, :ephemeral, v, &Review.ephemeral/1)
  defp review_opt({:json, v}, r), do: flag(r, :json, v, &Review.json/1)

  defp review_opt({:output_schema, v}, r),
    do: Review.output_schema(r, string!(:output_schema, v))

  defp review_opt({:output_last_message, v}, r),
    do: Review.output_last_message(r, string!(:output_last_message, v))

  defp review_opt({:config, v}, r), do: each(r, :config, v, &Review.config/2)
  defp review_opt({:enable, v}, r), do: each(r, :enable, v, &Review.enable/2)
  defp review_opt({:disable, v}, r), do: each(r, :disable, v, &Review.disable/2)
  defp review_opt(other, _r), do: unknown!(other, "CodexWrapper.review/1")

  # --- Value checks ---

  defp flag(acc, _key, true, fun), do: fun.(acc)
  defp flag(acc, _key, false, _fun), do: acc
  defp flag(_acc, key, v, _fun), do: bad_value!(key, v, "a boolean")

  defp each(acc, key, v, fun) when is_binary(v), do: fun.(acc, string!(key, v))

  defp each(acc, key, v, fun) when is_list(v),
    do: Enum.reduce(v, acc, fn item, a -> fun.(a, string!(key, item)) end)

  defp each(_acc, key, v, _fun), do: bad_value!(key, v, "a string or a list of strings")

  defp string!(_key, v) when is_binary(v), do: v
  defp string!(key, v), do: bad_value!(key, v, "a string")

  defp approval_policy!(:on_failure) do
    raise ArgumentError,
          "option :approval_policy: :on_failure is no longer a valid approval policy; " <>
            "the Codex CLI dropped it along with --ask-for-approval"
  end

  defp approval_policy!(v), do: member!(:approval_policy, v, @approval_policies)

  defp member!(key, v, allowed) do
    if v in allowed, do: v, else: bad_value!(key, v, "one of #{inspect(allowed)}")
  end

  defp bad_value!(key, v, expected) do
    raise ArgumentError, "option #{inspect(key)} expects #{expected}, got: #{inspect(v)}"
  end

  defp unknown!({key, _v}, where) do
    raise ArgumentError, "unknown option #{inspect(key)} for #{where}"
  end

  defp unknown!(other, where) do
    raise ArgumentError, "expected a keyword option for #{where}, got: #{inspect(other)}"
  end
end
