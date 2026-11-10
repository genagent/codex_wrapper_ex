defmodule CodexWrapper.ExecLevelTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{ExecFork, ExecResume, Options, Review}

  @exec_level [
    "--oss",
    "--local-provider",
    "ollama",
    "--profile",
    "ci",
    "--approve-for-me",
    "--cd",
    "/repo",
    "--add-dir",
    "/repo/.git",
    "--add-dir",
    "/tmp/out",
    "--color",
    "never"
  ]

  # Applies every exec-level builder of `module` to `command`.
  defp exec_level(command, module) do
    command
    |> module.profile("ci")
    |> module.add_dir("/repo/.git")
    |> module.add_dir("/tmp/out")
    |> module.cd("/repo")
    |> module.oss()
    |> module.local_provider("ollama")
    |> module.color(:never)
    |> module.approve_for_me()
  end

  defp after_subcommand(args, subcommand) do
    args |> Enum.drop_while(&(&1 != subcommand)) |> tl()
  end

  describe "ExecResume" do
    test "emits exec-level options between exec and resume" do
      args =
        ExecResume.new()
        |> ExecResume.session_id("thread-A")
        |> ExecResume.prompt("continue")
        |> exec_level(ExecResume)
        |> ExecResume.args()

      assert ["exec" | rest] = args
      assert Enum.take(rest, length(@exec_level) + 1) == @exec_level ++ ["resume"]
      refute "--profile" in after_subcommand(args, "resume")
    end

    test "emits search and approval as config, thread source and cyber program after resume" do
      args =
        ExecResume.new()
        |> ExecResume.last()
        |> ExecResume.config("model_verbosity=\"low\"")
        |> ExecResume.approval_policy(:never)
        |> ExecResume.search(:cached)
        |> ExecResume.thread_source("nightly")
        |> ExecResume.cyber_access_program(:daybreak_blue)
        |> ExecResume.args()

      assert Enum.take(args, 8) == [
               "exec",
               "resume",
               "-c",
               "model_verbosity=\"low\"",
               "-c",
               ~s(approval_policy="never"),
               "-c",
               ~s(web_search="cached")
             ]

      tail = after_subcommand(args, "resume")

      assert ["--thread-source", "nightly"] ==
               tail |> Enum.drop_while(&(&1 != "--thread-source")) |> Enum.take(2)

      assert ["--cyber-access-program", "daybreak_blue"] ==
               tail |> Enum.drop_while(&(&1 != "--cyber-access-program")) |> Enum.take(2)
    end

    test "search/1 is live search" do
      assert ~s(web_search="live") in (ExecResume.new()
                                       |> ExecResume.search()
                                       |> ExecResume.args())
    end

    test "has no worktree builder, which codex rejects on resume" do
      refute function_exported?(ExecResume, :worktree, 1)
    end
  end

  describe "ExecFork" do
    test "emits exec-level options between exec and fork" do
      args =
        ExecFork.new("thread-A")
        |> ExecFork.prompt("branch")
        |> exec_level(ExecFork)
        |> ExecFork.args()

      assert ["exec" | rest] = args
      assert Enum.take(rest, length(@exec_level) + 1) == @exec_level ++ ["fork"]
      assert Enum.take(args, -3) == ["--", "thread-A", "-"]
    end

    test "emits approval, search, worktree, thread source and cyber program" do
      args =
        ExecFork.new("thread-A")
        |> ExecFork.approval_policy(:on_request)
        |> ExecFork.search()
        |> ExecFork.worktree()
        |> ExecFork.thread_source("nightly")
        |> ExecFork.cyber_access_program(:standard)
        |> ExecFork.args()

      tail = after_subcommand(args, "fork")
      assert ~s(approval_policy="on-request") in tail
      assert ~s(web_search="live") in tail
      assert "--worktree" in tail
      assert "--thread-source" in tail
      assert "--cyber-access-program" in tail
    end

    test "worktree with ephemeral raises before spawning" do
      command = ExecFork.new("thread-A") |> ExecFork.worktree() |> ExecFork.ephemeral()

      assert_raise ArgumentError, ~r/worktree\/1 cannot be combined with ephemeral\/1/, fn ->
        ExecFork.args(command)
      end
    end

    test "approval_policy rejects :on_failure" do
      assert_raise ArgumentError, ~r/on_failure/, fn ->
        ExecFork.approval_policy(ExecFork.new("t"), :on_failure)
      end
    end
  end

  describe "Review" do
    test "emits exec-level options between exec and review" do
      args = Review.new() |> Review.uncommitted() |> exec_level(Review) |> Review.args()

      assert ["exec" | rest] = args
      assert Enum.take(rest, length(@exec_level) + 1) == @exec_level ++ ["review"]
      assert "--uncommitted" in after_subcommand(args, "review")
    end

    test "emits approval, search and thread source; no cyber program or worktree" do
      args =
        Review.new()
        |> Review.approval_policy(:untrusted)
        |> Review.search(:disabled)
        |> Review.thread_source("ci")
        |> Review.args()

      assert ~s(approval_policy="untrusted") in args
      assert ~s(web_search="disabled") in args
      assert "--thread-source" in after_subcommand(args, "review")
      refute function_exported?(Review, :cyber_access_program, 2)
      refute function_exported?(Review, :worktree, 1)
    end
  end

  describe "keyword options" do
    test "a resumed session turn takes the exec-level options" do
      args =
        Options.exec_resume("thread-A", "go",
          profile: "ci",
          cd: "/repo",
          add_dir: ["/repo/.git"],
          color: :never,
          oss: true,
          local_provider: "ollama",
          approve_for_me: true,
          search: :live,
          cyber_access_program: :standard
        )
        |> ExecResume.args()

      assert Enum.take(args, 12) ==
               ["exec", "--oss", "--local-provider", "ollama", "--profile", "ci"] ++
                 ["--approve-for-me", "--cd", "/repo", "--add-dir", "/repo/.git", "--color"]

      assert ~s(web_search="live") in args
      assert "--cyber-access-program" in args
    end

    test "worktree and thread_source stay first-turn only" do
      assert Options.first_turn_only() == [:worktree, :thread_source]
    end

    test "review/1 options reach the builder" do
      args =
        Options.review(
          uncommitted: true,
          profile: "ci",
          add_dir: "/repo/.git",
          approval_policy: :never,
          search: true,
          thread_source: "ci"
        )
        |> Review.args()

      assert Enum.take(args, 6) == [
               "exec",
               "--profile",
               "ci",
               "--add-dir",
               "/repo/.git",
               "review"
             ]

      assert ~s(approval_policy="never") in args
      assert ~s(web_search="live") in args
      assert "--thread-source" in args
    end
  end
end
