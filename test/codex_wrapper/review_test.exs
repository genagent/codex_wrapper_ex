defmodule CodexWrapper.ReviewTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Review

  describe "new/0" do
    test "defaults" do
      review = Review.new()
      assert review.prompt == nil
      assert review.uncommitted == false
      assert review.base == nil
      assert review.commit == nil
      assert review.title == nil
      assert review.model == nil
      assert review.full_auto == false
      assert review.dangerously_bypass_approvals_and_sandbox == false
      assert review.skip_git_repo_check == false
      assert review.ephemeral == false
      assert review.json == false
      assert review.output_schema == nil
      assert review.output_last_message == nil
      assert review.config_overrides == []
      assert review.enabled_features == []
      assert review.disabled_features == []
      assert review.strict_config == false
      assert review.ignore_user_config == false
      assert review.ignore_rules == false
      assert review.dangerously_bypass_hook_trust == false
    end
  end

  describe "builder functions" do
    test "prompt/2" do
      review = Review.new() |> Review.prompt("focus on correctness")
      assert review.prompt == "focus on correctness"
    end

    test "uncommitted/1" do
      review = Review.new() |> Review.uncommitted()
      assert review.uncommitted == true
    end

    test "base/2" do
      review = Review.new() |> Review.base("main")
      assert review.base == "main"
    end

    test "commit/2" do
      review = Review.new() |> Review.commit("abc123")
      assert review.commit == "abc123"
    end

    test "title/2" do
      review = Review.new() |> Review.title("Fix auth bug")
      assert review.title == "Fix auth bug"
    end

    test "model/2" do
      review = Review.new() |> Review.model("o3")
      assert review.model == "o3"
    end

    test "full_auto/1" do
      review = Review.new() |> Review.full_auto()
      assert review.full_auto == true
    end

    test "dangerously_bypass_approvals_and_sandbox/1" do
      review = Review.new() |> Review.dangerously_bypass_approvals_and_sandbox()
      assert review.dangerously_bypass_approvals_and_sandbox == true
    end

    test "skip_git_repo_check/1" do
      review = Review.new() |> Review.skip_git_repo_check()
      assert review.skip_git_repo_check == true
    end

    test "ephemeral/1" do
      review = Review.new() |> Review.ephemeral()
      assert review.ephemeral == true
    end

    test "json/1" do
      review = Review.new() |> Review.json()
      assert review.json == true
    end

    test "output_schema/2" do
      review = Review.new() |> Review.output_schema("/tmp/schema.json")
      assert review.output_schema == "/tmp/schema.json"
    end

    test "output_last_message/2" do
      review = Review.new() |> Review.output_last_message("/tmp/msg.json")
      assert review.output_last_message == "/tmp/msg.json"
    end

    test "config/2 accumulates" do
      review = Review.new() |> Review.config("key=val") |> Review.config("k2=v2")
      assert review.config_overrides == ["key=val", "k2=v2"]
    end

    test "enable/2 accumulates" do
      review = Review.new() |> Review.enable("feat1") |> Review.enable("feat2")
      assert review.enabled_features == ["feat1", "feat2"]
    end

    test "disable/2 accumulates" do
      review = Review.new() |> Review.disable("feat1")
      assert review.disabled_features == ["feat1"]
    end
  end

  describe "args/1" do
    test "minimal args" do
      args = Review.new() |> Review.args()
      assert args == ["exec", "review"]
    end

    test "uncommitted with model and json matches Rust ordering" do
      args =
        Review.new()
        |> Review.uncommitted()
        |> Review.model("gpt-5")
        |> Review.json()
        |> Review.prompt("focus on correctness")
        |> Review.args()

      assert args == [
               "exec",
               "review",
               "--uncommitted",
               "--model",
               "gpt-5",
               "--json",
               "focus on correctness"
             ]
    end

    test "base branch comparison" do
      args =
        Review.new()
        |> Review.base("main")
        |> Review.model("o3")
        |> Review.args()

      assert args == ["exec", "review", "--base", "main", "--model", "o3"]
    end

    test "specific commit review" do
      args =
        Review.new()
        |> Review.commit("abc123")
        |> Review.args()

      assert args == ["exec", "review", "--commit", "abc123"]
    end

    test "config overrides come first" do
      args =
        Review.new()
        |> Review.config("key=val")
        |> Review.model("o3")
        |> Review.args()

      config_idx = Enum.find_index(args, &(&1 == "-c"))
      model_idx = Enum.find_index(args, &(&1 == "--model"))
      assert config_idx < model_idx
    end

    test "list flags repeat" do
      args =
        Review.new()
        |> Review.enable("feat1")
        |> Review.enable("feat2")
        |> Review.disable("feat3")
        |> Review.args()

      assert "--enable" in args
      assert "feat1" in args
      assert "feat2" in args
      assert "--disable" in args
      assert "feat3" in args
    end

    test "boolean flags" do
      args =
        Review.new()
        |> Review.full_auto()
        |> Review.dangerously_bypass_approvals_and_sandbox()
        |> Review.skip_git_repo_check()
        |> Review.ephemeral()
        |> Review.args()

      refute "--full-auto" in args
      refute "--sandbox" in args
      assert ~s(sandbox_mode="workspace-write") in args
      assert "--dangerously-bypass-approvals-and-sandbox" in args
      assert "--skip-git-repo-check" in args
      assert "--ephemeral" in args
    end

    test "output_schema flag" do
      args =
        Review.new()
        |> Review.output_schema("/tmp/schema.json")
        |> Review.args()

      idx = Enum.find_index(args, &(&1 == "--output-schema"))
      assert Enum.at(args, idx + 1) == "/tmp/schema.json"
    end

    test "output_schema is omitted when unset" do
      refute "--output-schema" in Review.args(Review.new())
    end

    test "title flag" do
      args =
        Review.new()
        |> Review.title("Fix auth bug")
        |> Review.args()

      idx = Enum.find_index(args, &(&1 == "--title"))
      assert Enum.at(args, idx + 1) == "Fix auth bug"
    end

    test "prompt is always last when present" do
      args =
        Review.new()
        |> Review.model("o3")
        |> Review.json()
        |> Review.prompt("the prompt")
        |> Review.args()

      assert List.last(args) == "the prompt"
    end

    test "no prompt appended when nil" do
      args =
        Review.new()
        |> Review.uncommitted()
        |> Review.args()

      assert args == ["exec", "review", "--uncommitted"]
    end
  end

  describe "parse_output/2" do
    test "returns result for exit code 0" do
      assert {:ok, result} = Review.parse_output("review output\n", 0)
      assert result.stdout == "review output\n"
      assert result.exit_code == 0
      assert result.success == true
    end

    test "returns result for non-zero exit code" do
      assert {:ok, result} = Review.parse_output("error\n", 1)
      assert result.stdout == "error\n"
      assert result.exit_code == 1
      assert result.success == false
    end
  end

  describe "full_auto translation" do
    test "full_auto translates to sandbox_mode workspace-write" do
      args = Review.new() |> Review.full_auto() |> Review.args()
      idx = Enum.find_index(args, &(&1 == ~s(sandbox_mode="workspace-write")))
      assert Enum.at(args, idx - 1) == "-c"
      refute "--full-auto" in args
    end

    test "an explicit sandbox wins over full_auto" do
      args = Review.new() |> Review.full_auto() |> Review.sandbox(:read_only) |> Review.args()
      assert ~s(sandbox_mode="read-only") in args
      refute ~s(sandbox_mode="workspace-write") in args
    end

    test "no sandbox_mode override when neither is set" do
      args = Review.new() |> Review.args()
      refute Enum.any?(args, &String.starts_with?(&1, "sandbox_mode="))
    end
  end

  # `codex exec review` rejects `--sandbox` with "unexpected argument"; the
  # flag is accepted by `codex exec` only. See issue #80.
  describe "sandbox mode is a -c override, never a flag" do
    test "sandbox/2 emits -c sandbox_mode and no bare --sandbox" do
      for {mode, formatted} <- [
            {:read_only, "read-only"},
            {:workspace_write, "workspace-write"},
            {:danger_full_access, "danger-full-access"}
          ] do
        args = Review.new() |> Review.sandbox(mode) |> Review.args()

        refute "--sandbox" in args
        idx = Enum.find_index(args, &(&1 == ~s(sandbox_mode="#{formatted}")))
        assert Enum.at(args, idx - 1) == "-c"
      end
    end

    test "full_auto/1 emits no bare --sandbox either" do
      args = Review.new() |> Review.full_auto() |> Review.args()
      refute "--sandbox" in args
    end

    test "user config overrides come before the derived sandbox_mode" do
      args =
        Review.new()
        |> Review.config(~s(sandbox_mode="danger-full-access"))
        |> Review.sandbox(:read_only)
        |> Review.args()

      user_idx = Enum.find_index(args, &(&1 == ~s(sandbox_mode="danger-full-access")))
      derived_idx = Enum.find_index(args, &(&1 == ~s(sandbox_mode="read-only")))
      assert user_idx < derived_idx
    end
  end

  describe "config and trust flags" do
    test "strict_config/1" do
      review = Review.new() |> Review.strict_config()
      assert review.strict_config == true
      assert "--strict-config" in Review.args(review)
    end

    test "ignore_user_config/1" do
      review = Review.new() |> Review.ignore_user_config()
      assert review.ignore_user_config == true
      assert "--ignore-user-config" in Review.args(review)
    end

    test "ignore_rules/1" do
      review = Review.new() |> Review.ignore_rules()
      assert review.ignore_rules == true
      assert "--ignore-rules" in Review.args(review)
    end

    test "dangerously_bypass_hook_trust/1" do
      review = Review.new() |> Review.dangerously_bypass_hook_trust()
      assert review.dangerously_bypass_hook_trust == true
      assert "--dangerously-bypass-hook-trust" in Review.args(review)
    end

    test "flags precede the positional prompt" do
      args =
        Review.new()
        |> Review.prompt("focus on correctness")
        |> Review.strict_config()
        |> Review.ignore_rules()
        |> Review.args()

      assert List.last(args) == "focus on correctness"
      assert "--strict-config" in args
      assert "--ignore-rules" in args
    end

    test "none of the flags are emitted when unset" do
      args = Review.new() |> Review.args()

      refute "--strict-config" in args
      refute "--ignore-user-config" in args
      refute "--ignore-rules" in args
      refute "--dangerously-bypass-hook-trust" in args
    end
  end
end
