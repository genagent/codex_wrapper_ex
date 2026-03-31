defmodule CodexWrapper.ExecTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Exec

  describe "new/1" do
    test "sets the prompt" do
      exec = Exec.new("fix the test")
      assert exec.prompt == "fix the test"
    end

    test "defaults" do
      exec = Exec.new("prompt")
      assert exec.model == nil
      assert exec.sandbox == nil
      assert exec.approval_policy == nil
      assert exec.full_auto == false
      assert exec.dangerously_bypass_approvals_and_sandbox == false
      assert exec.cd == nil
      assert exec.skip_git_repo_check == false
      assert exec.add_dirs == []
      assert exec.search == false
      assert exec.ephemeral == false
      assert exec.output_schema == nil
      assert exec.json == false
      assert exec.output_last_message == nil
      assert exec.images == []
      assert exec.config_overrides == []
      assert exec.enabled_features == []
      assert exec.disabled_features == []
    end
  end

  describe "builder functions" do
    test "model/2" do
      exec = Exec.new("p") |> Exec.model("o3")
      assert exec.model == "o3"
    end

    test "sandbox/2" do
      exec = Exec.new("p") |> Exec.sandbox(:workspace_write)
      assert exec.sandbox == :workspace_write
    end

    test "approval_policy/2" do
      exec = Exec.new("p") |> Exec.approval_policy(:on_request)
      assert exec.approval_policy == :on_request
    end

    test "full_auto/1" do
      exec = Exec.new("p") |> Exec.full_auto()
      assert exec.full_auto == true
    end

    test "dangerously_bypass_approvals_and_sandbox/1" do
      exec = Exec.new("p") |> Exec.dangerously_bypass_approvals_and_sandbox()
      assert exec.dangerously_bypass_approvals_and_sandbox == true
    end

    test "cd/2" do
      exec = Exec.new("p") |> Exec.cd("/tmp")
      assert exec.cd == "/tmp"
    end

    test "skip_git_repo_check/1" do
      exec = Exec.new("p") |> Exec.skip_git_repo_check()
      assert exec.skip_git_repo_check == true
    end

    test "add_dir/2 accumulates" do
      exec = Exec.new("p") |> Exec.add_dir("/a") |> Exec.add_dir("/b")
      assert exec.add_dirs == ["/a", "/b"]
    end

    test "search/1" do
      exec = Exec.new("p") |> Exec.search()
      assert exec.search == true
    end

    test "ephemeral/1" do
      exec = Exec.new("p") |> Exec.ephemeral()
      assert exec.ephemeral == true
    end

    test "output_schema/2" do
      exec = Exec.new("p") |> Exec.output_schema("schema.json")
      assert exec.output_schema == "schema.json"
    end

    test "json/1" do
      exec = Exec.new("p") |> Exec.json()
      assert exec.json == true
    end

    test "output_last_message/2" do
      exec = Exec.new("p") |> Exec.output_last_message("/tmp/msg.json")
      assert exec.output_last_message == "/tmp/msg.json"
    end

    test "image/2 accumulates" do
      exec = Exec.new("p") |> Exec.image("a.png") |> Exec.image("b.png")
      assert exec.images == ["a.png", "b.png"]
    end

    test "config/2 accumulates" do
      exec = Exec.new("p") |> Exec.config("key=val") |> Exec.config("k2=v2")
      assert exec.config_overrides == ["key=val", "k2=v2"]
    end

    test "enable/2 accumulates" do
      exec = Exec.new("p") |> Exec.enable("feat1") |> Exec.enable("feat2")
      assert exec.enabled_features == ["feat1", "feat2"]
    end

    test "disable/2 accumulates" do
      exec = Exec.new("p") |> Exec.disable("feat1")
      assert exec.disabled_features == ["feat1"]
    end
  end

  describe "args/1" do
    test "minimal args" do
      args = Exec.new("fix the test") |> Exec.args()
      assert args == ["exec", "fix the test"]
    end

    test "full args match Rust ordering" do
      args =
        Exec.new("fix the test")
        |> Exec.model("gpt-5")
        |> Exec.sandbox(:workspace_write)
        |> Exec.approval_policy(:on_request)
        |> Exec.skip_git_repo_check()
        |> Exec.ephemeral()
        |> Exec.json()
        |> Exec.args()

      assert args == [
               "exec",
               "--model",
               "gpt-5",
               "--sandbox",
               "workspace-write",
               "--ask-for-approval",
               "on-request",
               "--skip-git-repo-check",
               "--ephemeral",
               "--json",
               "fix the test"
             ]
    end

    test "config overrides come first" do
      args =
        Exec.new("prompt")
        |> Exec.config("key=val")
        |> Exec.model("o3")
        |> Exec.args()

      config_idx = Enum.find_index(args, &(&1 == "-c"))
      model_idx = Enum.find_index(args, &(&1 == "--model"))
      assert config_idx < model_idx
    end

    test "list flags repeat" do
      args =
        Exec.new("prompt")
        |> Exec.image("a.png")
        |> Exec.image("b.png")
        |> Exec.add_dir("/x")
        |> Exec.add_dir("/y")
        |> Exec.args()

      assert "--image" in args
      assert "a.png" in args
      assert "b.png" in args
      assert "--add-dir" in args
      assert "/x" in args
      assert "/y" in args
    end

    test "boolean flags" do
      args =
        Exec.new("prompt")
        |> Exec.full_auto()
        |> Exec.dangerously_bypass_approvals_and_sandbox()
        |> Exec.search()
        |> Exec.args()

      assert "--full-auto" in args
      assert "--dangerously-bypass-approvals-and-sandbox" in args
      assert "--search" in args
    end

    test "sandbox modes" do
      assert "--sandbox" in (Exec.new("p") |> Exec.sandbox(:read_only) |> Exec.args())

      args = Exec.new("p") |> Exec.sandbox(:read_only) |> Exec.args()
      idx = Enum.find_index(args, &(&1 == "--sandbox"))
      assert Enum.at(args, idx + 1) == "read-only"

      args = Exec.new("p") |> Exec.sandbox(:danger_full_access) |> Exec.args()
      idx = Enum.find_index(args, &(&1 == "--sandbox"))
      assert Enum.at(args, idx + 1) == "danger-full-access"
    end

    test "approval policies" do
      args = Exec.new("p") |> Exec.approval_policy(:untrusted) |> Exec.args()
      idx = Enum.find_index(args, &(&1 == "--ask-for-approval"))
      assert Enum.at(args, idx + 1) == "untrusted"

      args = Exec.new("p") |> Exec.approval_policy(:never) |> Exec.args()
      idx = Enum.find_index(args, &(&1 == "--ask-for-approval"))
      assert Enum.at(args, idx + 1) == "never"
    end

    test "prompt is always last" do
      args =
        Exec.new("the prompt")
        |> Exec.model("o3")
        |> Exec.json()
        |> Exec.args()

      assert List.last(args) == "the prompt"
    end
  end

  describe "parse_output/2" do
    test "returns result for exit code 0" do
      assert {:ok, result} = Exec.parse_output("output text\n", 0)
      assert result.stdout == "output text\n"
      assert result.exit_code == 0
      assert result.success == true
    end

    test "returns result for non-zero exit code" do
      assert {:ok, result} = Exec.parse_output("error\n", 1)
      assert result.stdout == "error\n"
      assert result.exit_code == 1
      assert result.success == false
    end
  end
end
