defmodule CodexWrapper.OptionsTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, Exec, ExecResume, Options, Review, Session}

  @moduletag :tmp_dir

  # One row per README "Exec options" entry: the option and the argv
  # fragment the Exec builder emits for it.
  @exec_rows [
    {[model: "o3"], ["--model", "o3"]},
    {[profile: "fast"], ["--profile", "fast"]},
    {[sandbox: :read_only], ["--sandbox", "read-only"]},
    {[approval_policy: :never], ["-c", ~s(approval_policy="never")]},
    {[full_auto: true], ["--sandbox", "workspace-write"]},
    {[cd: "/repo"], ["--cd", "/repo"]},
    {[skip_git_repo_check: true], ["--skip-git-repo-check"]},
    {[search: true], ["-c", ~s(web_search="live")]},
    {[search: :cached], ["-c", ~s(web_search="cached")]},
    {[ephemeral: true], ["--ephemeral"]},
    {[json: true], ["--json"]},
    {[output_schema: "/s.json"], ["--output-schema", "/s.json"]},
    {[output_last_message: "/out.txt"], ["--output-last-message", "/out.txt"]},
    {[strict_config: true], ["--strict-config"]},
    {[ignore_user_config: true], ["--ignore-user-config"]},
    {[ignore_rules: true], ["--ignore-rules"]},
    {[dangerously_bypass_hook_trust: true], ["--dangerously-bypass-hook-trust"]},
    {[color: :never], ["--color", "never"]},
    {[oss: true], ["--oss"]},
    {[local_provider: "ollama"], ["--local-provider", "ollama"]},
    {[add_dir: "/extra"], ["--add-dir", "/extra"]},
    {[image: "/a.png"], ["--image", "/a.png"]},
    {[config: ~s(model="o3")], ["-c", ~s(model="o3")]},
    {[enable: "f1"], ["--enable", "f1"]},
    {[disable: "f2"], ["--disable", "f2"]}
  ]

  describe "exec/2" do
    for {opts, fragment} <- @exec_rows do
      @opts opts
      @fragment fragment

      test "maps #{inspect(opts)}" do
        args = Exec.args(Options.exec("hello", @opts))
        assert contains?(args, @fragment), "#{inspect(@fragment)} not in #{inspect(args)}"
        assert List.last(args) == "hello"
      end
    end

    test "false booleans emit nothing" do
      args = Exec.args(Options.exec("hi", full_auto: false, oss: false, search: false))
      assert args == ["exec", "--", "hi"]
    end

    test "list values emit one flag each" do
      args = Exec.args(Options.exec("hi", image: ["/a.png", "/b.png"], add_dir: ["/x", "/y"]))
      assert contains?(args, ["--image", "/a.png", "--image", "/b.png"])
      assert contains?(args, ["--add-dir", "/x", "--add-dir", "/y"])
    end

    test "raises on an unknown option" do
      assert_raise ArgumentError, ~r/unknown option :sandbox_mode/, fn ->
        Options.exec("hi", sandbox_mode: :read_only)
      end
    end

    test "raises on a value of the wrong shape" do
      assert_raise ArgumentError, ~r/:full_auto expects a boolean/, fn ->
        Options.exec("hi", full_auto: "yes")
      end

      assert_raise ArgumentError, ~r/:search expects one of/, fn ->
        Options.exec("hi", search: "live")
      end

      assert_raise ArgumentError, ~r/:sandbox expects one of/, fn ->
        Options.exec("hi", sandbox: "read-only")
      end

      assert_raise ArgumentError, ~r/:image expects a string/, fn ->
        Options.exec("hi", image: [:a])
      end
    end

    test "keeps the builder's message for :on_failure" do
      assert_raise ArgumentError, ~r/no longer a valid approval policy/, fn ->
        Options.exec("hi", approval_policy: :on_failure)
      end
    end
  end

  describe "review/1" do
    test "maps sandbox and the isolation options" do
      args =
        Review.args(
          Options.review(
            uncommitted: true,
            sandbox: :read_only,
            ignore_user_config: true,
            strict_config: true,
            ignore_rules: true,
            dangerously_bypass_hook_trust: true,
            config: "a=1",
            enable: "f1",
            disable: ["f2"]
          )
        )

      assert contains?(args, ["-c", "a=1", "-c", ~s(sandbox_mode="read-only")])
      assert contains?(args, ["--enable", "f1", "--disable", "f2"])

      for flag <- [
            "--uncommitted",
            "--ignore-user-config",
            "--strict-config",
            "--ignore-rules",
            "--dangerously-bypass-hook-trust"
          ] do
        assert flag in args
      end
    end

    test "full_auto emits a sandbox_mode override" do
      args = Review.args(Options.review(full_auto: true))
      assert contains?(args, ["-c", ~s(sandbox_mode="workspace-write")])
    end

    test "raises on an unknown option" do
      assert_raise ArgumentError, ~r/unknown option :profile/, fn ->
        Options.review(profile: "fast")
      end
    end
  end

  describe "exec_resume/3" do
    test "maps sandbox, approval policy and the isolation options" do
      args =
        ExecResume.args(
          Options.exec_resume("thread-A", "next",
            sandbox: :read_only,
            approval_policy: :never,
            ignore_user_config: true,
            strict_config: true,
            ignore_rules: true,
            model: "m1"
          )
        )

      assert contains?(args, [
               "-c",
               ~s(approval_policy="never"),
               "-c",
               ~s(sandbox_mode="read-only")
             ])

      assert "--ignore-user-config" in args
      assert "--strict-config" in args
      assert "--ignore-rules" in args
      assert Enum.take(args, -3) == ["--", "thread-A", "next"]
    end

    test "raises on a first-turn-only option" do
      for key <- Options.first_turn_only() do
        assert_raise ArgumentError, ~r/first turn of a session only/, fn ->
          Options.exec_resume("t", "p", [{key, "x"}])
        end
      end
    end
  end

  describe "CodexWrapper.exec/2, exec_json/2, stream/2 and review/1" do
    setup %{tmp_dir: dir} do
      log = Path.join(dir, "argv.log")
      binary = argv_logger(dir, log, "")
      {:ok, log: log, config: [binary: binary]}
    end

    test "emit the isolation options", %{log: log, config: config} do
      opts =
        config ++
          [sandbox: :read_only, ignore_user_config: true, strict_config: true, ignore_rules: true]

      {:ok, _} = CodexWrapper.exec("hello", opts)
      {:ok, _} = CodexWrapper.exec_json("hello", opts)
      _ = "hello" |> CodexWrapper.stream(opts) |> Enum.to_list()
      {:ok, _} = CodexWrapper.review(Keyword.put(opts, :uncommitted, true))

      lines = read_log(log)
      assert length(lines) == 4

      for line <- lines do
        assert line =~ "[--ignore-user-config]"
        assert line =~ "[--strict-config]"
        assert line =~ "[--ignore-rules]"
      end
    end

    test "raise before spawning on an unknown option", %{log: log, config: config} do
      assert_raise ArgumentError, fn -> CodexWrapper.exec("hello", config ++ [bogus: 1]) end
      assert_raise ArgumentError, fn -> CodexWrapper.review(config ++ [bogus: 1]) end
      refute File.exists?(log)
    end
  end

  describe "Session" do
    setup %{tmp_dir: dir} do
      log = Path.join(dir, "argv.log")
      thread = ~s(printf '%s\\n' '{"type":"thread.started","thread_id":"thread-A"}')
      {:ok, log: log, config: Config.new(binary: argv_logger(dir, log, thread))}
    end

    test "resumed turns keep sandbox, approval and isolation settings", ctx do
      session =
        Session.new(ctx.config,
          sandbox: :read_only,
          approval_policy: :never,
          ignore_user_config: true,
          strict_config: true,
          ignore_rules: true,
          profile: "fast",
          model: "m1"
        )

      {:ok, session, _} = Session.send(session, "first")
      {:ok, _session, _} = Session.send(session, "second")

      [turn1, turn2] = read_log(ctx.log)

      assert turn1 =~ "[--profile] [fast]"
      assert turn1 =~ "[--sandbox] [read-only]"

      assert turn2 =~ "[exec] [resume]"
      assert turn2 =~ ~s([-c] [approval_policy="never"] [-c] [sandbox_mode="read-only"])
      assert turn2 =~ "[--ignore-user-config]"
      assert turn2 =~ "[--strict-config]"
      assert turn2 =~ "[--ignore-rules]"
      assert turn2 =~ "[--model] [m1]"
      refute turn2 =~ "--profile"
      assert turn2 =~ "[--] [thread-A] [second]"
    end

    test "an explicit sandbox wins over full_auto on resumed turns", ctx do
      session = Session.new(ctx.config, sandbox: :read_only, full_auto: true)
      {:ok, session, _} = Session.send(session, "first")
      {:ok, _session, _} = Session.send(session, "second")

      [_turn1, turn2] = read_log(ctx.log)
      assert turn2 =~ ~s([sandbox_mode="read-only"])
      refute turn2 =~ "workspace-write"
    end

    test "a first-turn-only option passed per call on a resumed turn raises", ctx do
      session = Session.resume(ctx.config, "thread-A")

      assert_raise ArgumentError, ~r/first turn of a session only/, fn ->
        Session.send(session, "next", profile: "fast")
      end
    end

    test "new/2 and resume/3 validate their options", ctx do
      assert_raise ArgumentError, ~r/unknown option :bogus/, fn ->
        Session.new(ctx.config, bogus: true)
      end

      assert_raise ArgumentError, ~r/first turn of a session only/, fn ->
        Session.resume(ctx.config, "thread-A", profile: "fast")
      end
    end
  end

  # A fake codex that appends its argv, each element in brackets, to `log`,
  # then runs `body`.
  defp argv_logger(dir, log, body) do
    path = Path.join(dir, "fake_codex")

    File.write!(path, """
    #!/bin/sh
    line=""
    for a in "$@"; do line="$line[$a] "; done
    printf '%s\\n' "$line" >> '#{log}'
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp read_log(log), do: log |> File.read!() |> String.split("\n", trim: true)

  defp contains?(list, fragment) do
    n = length(fragment)
    list |> Enum.chunk_every(n, 1, :discard) |> Enum.member?(fragment)
  end
end
