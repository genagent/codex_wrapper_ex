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
      assert exec.search == nil
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

    test "approval_policy/2 rejects the removed :on_failure policy" do
      assert_raise ArgumentError, ~r/no longer a valid approval policy/, fn ->
        Exec.new("p") |> Exec.approval_policy(:on_failure)
      end
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

    test "search/1 defaults to live" do
      exec = Exec.new("p") |> Exec.search()
      assert exec.search == :live
    end

    test "search/2 sets the mode" do
      assert (Exec.new("p") |> Exec.search(:cached)).search == :cached
      assert (Exec.new("p") |> Exec.search(:disabled)).search == :disabled
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
               "-c",
               ~s(approval_policy="on-request"),
               "--model",
               "gpt-5",
               "--sandbox",
               "workspace-write",
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
        |> Exec.args()

      assert "--full-auto" in args
      assert "--dangerously-bypass-approvals-and-sandbox" in args
    end

    test "search/1 emits the web_search config key set to live" do
      args = Exec.new("p") |> Exec.search() |> Exec.args()
      assert args == ["exec", "-c", ~s(web_search="live"), "p"]
    end

    test "search/2 emits each web search mode" do
      for {mode, value} <- [
            {:cached, "cached"},
            {:indexed, "indexed"},
            {:live, "live"},
            {:disabled, "disabled"}
          ] do
        args = Exec.new("p") |> Exec.search(mode) |> Exec.args()
        idx = Enum.find_index(args, &(&1 == "-c"))
        assert Enum.at(args, idx + 1) == ~s(web_search="#{value}")
      end
    end

    test "the removed --search flag is never emitted" do
      args = Exec.new("p") |> Exec.search() |> Exec.args()
      refute "--search" in args
    end

    test "no web_search override when search is unset" do
      args = Exec.new("p") |> Exec.args()
      refute "-c" in args
      refute Enum.any?(args, &String.starts_with?(&1, "web_search="))
    end

    test "user config overrides precede the web_search override" do
      args =
        Exec.new("p")
        |> Exec.config(~s(model_reasoning_effort="high"))
        |> Exec.search()
        |> Exec.args()

      assert args == [
               "exec",
               "-c",
               ~s(model_reasoning_effort="high"),
               "-c",
               ~s(web_search="live"),
               "p"
             ]
    end

    test "an explicit web_search config override is left alone" do
      args = Exec.new("p") |> Exec.config(~s(web_search="cached")) |> Exec.args()
      assert args == ["exec", "-c", ~s(web_search="cached"), "p"]
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

    test "approval policies emit the approval_policy config key" do
      for {policy, value} <- [
            {:untrusted, "untrusted"},
            {:on_request, "on-request"},
            {:never, "never"}
          ] do
        args = Exec.new("p") |> Exec.approval_policy(policy) |> Exec.args()
        idx = Enum.find_index(args, &(&1 == "-c"))
        assert Enum.at(args, idx + 1) == ~s(approval_policy="#{value}")
      end
    end

    test "the removed --ask-for-approval flag is never emitted" do
      args = Exec.new("p") |> Exec.approval_policy(:never) |> Exec.args()
      refute "--ask-for-approval" in args
    end

    test "no approval_policy override when unset" do
      args = Exec.new("p") |> Exec.args()
      refute "-c" in args
      refute Enum.any?(args, &String.starts_with?(&1, "approval_policy="))
    end

    test "user config overrides precede the approval_policy override" do
      args =
        Exec.new("p")
        |> Exec.config("model_reasoning_effort=\"high\"")
        |> Exec.approval_policy(:never)
        |> Exec.args()

      assert args == [
               "exec",
               "-c",
               ~s(model_reasoning_effort="high"),
               "-c",
               ~s(approval_policy="never"),
               "p"
             ]
    end

    test "an explicit approval_policy config override is left alone" do
      args =
        Exec.new("p")
        |> Exec.config(~s(approval_policy="untrusted"))
        |> Exec.args()

      assert args == ["exec", "-c", ~s(approval_policy="untrusted"), "p"]
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
