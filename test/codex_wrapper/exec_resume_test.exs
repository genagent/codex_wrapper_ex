defmodule CodexWrapper.ExecResumeTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.ExecResume

  describe "new/0" do
    test "defaults" do
      exec = ExecResume.new()
      assert exec.session_id == nil
      assert exec.prompt == nil
      assert exec.last == false
      assert exec.all == false
      assert exec.model == nil
      assert exec.profile == nil
      assert exec.full_auto == false
      assert exec.dangerously_bypass_approvals_and_sandbox == false
      assert exec.skip_git_repo_check == false
      assert exec.ephemeral == false
      assert exec.json == false
      assert exec.output_last_message == nil
      assert exec.images == []
      assert exec.config_overrides == []
      assert exec.enabled_features == []
      assert exec.disabled_features == []
    end
  end

  describe "builder functions" do
    test "session_id/2" do
      exec = ExecResume.new() |> ExecResume.session_id("abc-123")
      assert exec.session_id == "abc-123"
    end

    test "prompt/2" do
      exec = ExecResume.new() |> ExecResume.prompt("continue")
      assert exec.prompt == "continue"
    end

    test "last/1" do
      exec = ExecResume.new() |> ExecResume.last()
      assert exec.last == true
    end

    test "all/1" do
      exec = ExecResume.new() |> ExecResume.all()
      assert exec.all == true
    end

    test "model/2" do
      exec = ExecResume.new() |> ExecResume.model("o3")
      assert exec.model == "o3"
    end

    test "profile/2" do
      exec = ExecResume.new() |> ExecResume.profile("fast")
      assert exec.profile == "fast"
    end

    test "full_auto/1" do
      exec = ExecResume.new() |> ExecResume.full_auto()
      assert exec.full_auto == true
    end

    test "dangerously_bypass_approvals_and_sandbox/1" do
      exec = ExecResume.new() |> ExecResume.dangerously_bypass_approvals_and_sandbox()
      assert exec.dangerously_bypass_approvals_and_sandbox == true
    end

    test "skip_git_repo_check/1" do
      exec = ExecResume.new() |> ExecResume.skip_git_repo_check()
      assert exec.skip_git_repo_check == true
    end

    test "ephemeral/1" do
      exec = ExecResume.new() |> ExecResume.ephemeral()
      assert exec.ephemeral == true
    end

    test "json/1" do
      exec = ExecResume.new() |> ExecResume.json()
      assert exec.json == true
    end

    test "output_last_message/2" do
      exec = ExecResume.new() |> ExecResume.output_last_message("/tmp/msg.json")
      assert exec.output_last_message == "/tmp/msg.json"
    end

    test "image/2 accumulates" do
      exec = ExecResume.new() |> ExecResume.image("a.png") |> ExecResume.image("b.png")
      assert exec.images == ["a.png", "b.png"]
    end

    test "config/2 accumulates" do
      exec = ExecResume.new() |> ExecResume.config("key=val") |> ExecResume.config("k2=v2")
      assert exec.config_overrides == ["key=val", "k2=v2"]
    end

    test "enable/2 accumulates" do
      exec = ExecResume.new() |> ExecResume.enable("feat1") |> ExecResume.enable("feat2")
      assert exec.enabled_features == ["feat1", "feat2"]
    end

    test "disable/2 accumulates" do
      exec = ExecResume.new() |> ExecResume.disable("feat1")
      assert exec.disabled_features == ["feat1"]
    end
  end

  describe "args/1" do
    test "minimal args" do
      args = ExecResume.new() |> ExecResume.args()
      assert args == ["exec", "resume"]
    end

    test "with session_id only" do
      args = ExecResume.new() |> ExecResume.session_id("abc-123") |> ExecResume.args()
      assert args == ["exec", "resume", "abc-123"]
    end

    test "with session_id and prompt" do
      args =
        ExecResume.new()
        |> ExecResume.session_id("abc-123")
        |> ExecResume.prompt("continue")
        |> ExecResume.args()

      assert args == ["exec", "resume", "abc-123", "continue"]
    end

    test "with --last flag" do
      args = ExecResume.new() |> ExecResume.last() |> ExecResume.args()
      assert "--last" in args
    end

    test "full args match Rust ordering" do
      args =
        ExecResume.new()
        |> ExecResume.model("gpt-5")
        |> ExecResume.full_auto()
        |> ExecResume.skip_git_repo_check()
        |> ExecResume.json()
        |> ExecResume.session_id("abc-123")
        |> ExecResume.prompt("continue")
        |> ExecResume.args()

      assert args == [
               "exec",
               "resume",
               "--model",
               "gpt-5",
               "--sandbox",
               "workspace-write",
               "--skip-git-repo-check",
               "--json",
               "abc-123",
               "continue"
             ]
    end

    test "profile emits --profile after --model" do
      args =
        ExecResume.new()
        |> ExecResume.model("o3")
        |> ExecResume.profile("fast")
        |> ExecResume.prompt("continue")
        |> ExecResume.args()

      assert args == ["exec", "resume", "--model", "o3", "--profile", "fast", "continue"]
    end

    test "profile is omitted when unset" do
      args = ExecResume.new() |> ExecResume.model("o3") |> ExecResume.args()
      refute "--profile" in args
    end

    test "config overrides come first" do
      args =
        ExecResume.new()
        |> ExecResume.config("key=val")
        |> ExecResume.model("o3")
        |> ExecResume.args()

      config_idx = Enum.find_index(args, &(&1 == "-c"))
      model_idx = Enum.find_index(args, &(&1 == "--model"))
      assert config_idx < model_idx
    end

    test "session_id and prompt are last" do
      args =
        ExecResume.new()
        |> ExecResume.model("o3")
        |> ExecResume.json()
        |> ExecResume.session_id("sess-1")
        |> ExecResume.prompt("the prompt")
        |> ExecResume.args()

      assert Enum.slice(args, -2, 2) == ["sess-1", "the prompt"]
    end

    test "boolean flags" do
      args =
        ExecResume.new()
        |> ExecResume.full_auto()
        |> ExecResume.dangerously_bypass_approvals_and_sandbox()
        |> ExecResume.last()
        |> ExecResume.all()
        |> ExecResume.args()

      refute "--full-auto" in args
      assert "--sandbox" in args
      assert "workspace-write" in args
      assert "--dangerously-bypass-approvals-and-sandbox" in args
      assert "--last" in args
      assert "--all" in args
    end

    test "list flags repeat" do
      args =
        ExecResume.new()
        |> ExecResume.image("a.png")
        |> ExecResume.image("b.png")
        |> ExecResume.args()

      assert "--image" in args
      assert "a.png" in args
      assert "b.png" in args
    end
  end

  describe "parse_output/2" do
    test "returns result for exit code 0" do
      assert {:ok, result} = ExecResume.parse_output("output text\n", 0)
      assert result.stdout == "output text\n"
      assert result.exit_code == 0
      assert result.success == true
    end

    test "returns result for non-zero exit code" do
      assert {:ok, result} = ExecResume.parse_output("error\n", 1)
      assert result.stdout == "error\n"
      assert result.exit_code == 1
      assert result.success == false
    end
  end

  describe "full_auto translation" do
    test "full_auto translates to --sandbox workspace-write" do
      args = ExecResume.new() |> ExecResume.full_auto() |> ExecResume.args()
      idx = Enum.find_index(args, &(&1 == "--sandbox"))
      assert Enum.at(args, idx + 1) == "workspace-write"
      refute "--full-auto" in args
    end

    test "an explicit sandbox wins over full_auto" do
      args =
        ExecResume.new()
        |> ExecResume.full_auto()
        |> ExecResume.sandbox(:read_only)
        |> ExecResume.args()

      idx = Enum.find_index(args, &(&1 == "--sandbox"))
      assert Enum.at(args, idx + 1) == "read-only"
      refute "workspace-write" in args
    end

    test "no --sandbox when neither is set" do
      args = ExecResume.new() |> ExecResume.args()
      refute "--sandbox" in args
    end
  end
end
