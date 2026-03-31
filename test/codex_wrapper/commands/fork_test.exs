defmodule CodexWrapper.Commands.ForkTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Fork

  describe "new/0" do
    test "defaults" do
      fork = Fork.new()
      assert fork.session_id == nil
      assert fork.prompt == nil
      assert fork.last == false
      assert fork.all == false
      assert fork.model == nil
      assert fork.sandbox == nil
      assert fork.approval_policy == nil
      assert fork.full_auto == false
      assert fork.dangerously_bypass_approvals_and_sandbox == false
      assert fork.cd == nil
      assert fork.search == false
      assert fork.add_dirs == []
      assert fork.images == []
      assert fork.config_overrides == []
      assert fork.enabled_features == []
      assert fork.disabled_features == []
    end
  end

  describe "builder functions" do
    test "session_id/2" do
      fork = Fork.new() |> Fork.session_id("abc-123")
      assert fork.session_id == "abc-123"
    end

    test "prompt/2" do
      fork = Fork.new() |> Fork.prompt("try again")
      assert fork.prompt == "try again"
    end

    test "last/1" do
      fork = Fork.new() |> Fork.last()
      assert fork.last == true
    end

    test "all/1" do
      fork = Fork.new() |> Fork.all()
      assert fork.all == true
    end

    test "model/2" do
      fork = Fork.new() |> Fork.model("o3")
      assert fork.model == "o3"
    end

    test "sandbox/2" do
      fork = Fork.new() |> Fork.sandbox(:read_only)
      assert fork.sandbox == :read_only
    end

    test "approval_policy/2" do
      fork = Fork.new() |> Fork.approval_policy(:on_failure)
      assert fork.approval_policy == :on_failure
    end

    test "full_auto/1" do
      fork = Fork.new() |> Fork.full_auto()
      assert fork.full_auto == true
    end

    test "dangerously_bypass_approvals_and_sandbox/1" do
      fork = Fork.new() |> Fork.dangerously_bypass_approvals_and_sandbox()
      assert fork.dangerously_bypass_approvals_and_sandbox == true
    end

    test "cd/2" do
      fork = Fork.new() |> Fork.cd("/tmp/project")
      assert fork.cd == "/tmp/project"
    end

    test "search/1" do
      fork = Fork.new() |> Fork.search()
      assert fork.search == true
    end

    test "add_dir/2 accumulates" do
      fork = Fork.new() |> Fork.add_dir("/src") |> Fork.add_dir("/lib")
      assert fork.add_dirs == ["/src", "/lib"]
    end

    test "image/2 accumulates" do
      fork = Fork.new() |> Fork.image("a.png") |> Fork.image("b.png")
      assert fork.images == ["a.png", "b.png"]
    end

    test "config/2 accumulates" do
      fork = Fork.new() |> Fork.config("key=val") |> Fork.config("k2=v2")
      assert fork.config_overrides == ["key=val", "k2=v2"]
    end

    test "enable/2 accumulates" do
      fork = Fork.new() |> Fork.enable("feat1") |> Fork.enable("feat2")
      assert fork.enabled_features == ["feat1", "feat2"]
    end

    test "disable/2 accumulates" do
      fork = Fork.new() |> Fork.disable("feat1")
      assert fork.disabled_features == ["feat1"]
    end
  end

  describe "args/1" do
    test "minimal args" do
      args = Fork.new() |> Fork.args()
      assert args == ["fork"]
    end

    test "with session_id only" do
      args = Fork.new() |> Fork.session_id("abc-123") |> Fork.args()
      assert args == ["fork", "abc-123"]
    end

    test "with session_id and prompt" do
      args =
        Fork.new()
        |> Fork.session_id("abc-123")
        |> Fork.prompt("try again")
        |> Fork.args()

      assert args == ["fork", "abc-123", "try again"]
    end

    test "with --last flag" do
      args = Fork.new() |> Fork.last() |> Fork.args()
      assert "--last" in args
    end

    test "fork last with model and prompt matches Rust ordering" do
      args =
        Fork.new()
        |> Fork.last()
        |> Fork.model("gpt-5")
        |> Fork.prompt("take a different approach")
        |> Fork.args()

      assert args == [
               "fork",
               "--last",
               "--model",
               "gpt-5",
               "take a different approach"
             ]
    end

    test "fork session_id with full_auto and search matches Rust ordering" do
      args =
        Fork.new()
        |> Fork.session_id("abc-123")
        |> Fork.full_auto()
        |> Fork.search()
        |> Fork.args()

      assert args == ["fork", "--full-auto", "--search", "abc-123"]
    end

    test "config overrides come first" do
      args =
        Fork.new()
        |> Fork.config("key=val")
        |> Fork.model("o3")
        |> Fork.args()

      config_idx = Enum.find_index(args, &(&1 == "-c"))
      model_idx = Enum.find_index(args, &(&1 == "--model"))
      assert config_idx < model_idx
    end

    test "session_id and prompt are last" do
      args =
        Fork.new()
        |> Fork.model("o3")
        |> Fork.search()
        |> Fork.session_id("sess-1")
        |> Fork.prompt("the prompt")
        |> Fork.args()

      assert Enum.slice(args, -2, 2) == ["sess-1", "the prompt"]
    end

    test "boolean flags" do
      args =
        Fork.new()
        |> Fork.full_auto()
        |> Fork.dangerously_bypass_approvals_and_sandbox()
        |> Fork.last()
        |> Fork.all()
        |> Fork.search()
        |> Fork.args()

      assert "--full-auto" in args
      assert "--dangerously-bypass-approvals-and-sandbox" in args
      assert "--last" in args
      assert "--all" in args
      assert "--search" in args
    end

    test "sandbox mode formatting" do
      args = Fork.new() |> Fork.sandbox(:workspace_write) |> Fork.args()
      assert args == ["fork", "--sandbox", "workspace-write"]
    end

    test "approval policy formatting" do
      args = Fork.new() |> Fork.approval_policy(:on_failure) |> Fork.args()
      assert args == ["fork", "--ask-for-approval", "on-failure"]
    end

    test "list flags repeat" do
      args =
        Fork.new()
        |> Fork.image("a.png")
        |> Fork.image("b.png")
        |> Fork.args()

      assert "--image" in args
      assert "a.png" in args
      assert "b.png" in args
    end

    test "add_dir flags repeat" do
      args =
        Fork.new()
        |> Fork.add_dir("/src")
        |> Fork.add_dir("/lib")
        |> Fork.args()

      assert args == ["fork", "--add-dir", "/src", "--add-dir", "/lib"]
    end

    test "full args" do
      args =
        Fork.new()
        |> Fork.config("key=val")
        |> Fork.enable("feat1")
        |> Fork.disable("feat2")
        |> Fork.last()
        |> Fork.image("img.png")
        |> Fork.model("o3")
        |> Fork.sandbox(:read_only)
        |> Fork.approval_policy(:never)
        |> Fork.full_auto()
        |> Fork.cd("/tmp")
        |> Fork.search()
        |> Fork.add_dir("/extra")
        |> Fork.session_id("sess-1")
        |> Fork.prompt("do it")
        |> Fork.args()

      assert args == [
               "fork",
               "-c",
               "key=val",
               "--enable",
               "feat1",
               "--disable",
               "feat2",
               "--last",
               "--image",
               "img.png",
               "--model",
               "o3",
               "--sandbox",
               "read-only",
               "--ask-for-approval",
               "never",
               "--full-auto",
               "--cd",
               "/tmp",
               "--search",
               "--add-dir",
               "/extra",
               "sess-1",
               "do it"
             ]
    end
  end

  describe "parse_output/2" do
    test "returns result for exit code 0" do
      assert {:ok, result} = Fork.parse_output("output text\n", 0)
      assert result.stdout == "output text\n"
      assert result.exit_code == 0
      assert result.success == true
    end

    test "returns result for non-zero exit code" do
      assert {:ok, result} = Fork.parse_output("error\n", 1)
      assert result.stdout == "error\n"
      assert result.exit_code == 1
      assert result.success == false
    end
  end
end
