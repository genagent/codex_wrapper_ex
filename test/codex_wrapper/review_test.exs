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
      assert review.output_last_message == nil
      assert review.config_overrides == []
      assert review.enabled_features == []
      assert review.disabled_features == []
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
               "--model", "gpt-5",
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

      assert "--full-auto" in args
      assert "--dangerously-bypass-approvals-and-sandbox" in args
      assert "--skip-git-repo-check" in args
      assert "--ephemeral" in args
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
end
