defmodule CodexWrapper.ReleaseEnvTest do
  # These tests temporarily replace the VM's release environment.
  use ExUnit.Case, async: false

  alias CodexWrapper.Commands
  alias CodexWrapper.{Config, Exec, ExecFork, ExecResume, Review, Runner, Session}

  @moduletag :tmp_dir
  @unset "<unset>"
  @clean_path "/usr/bin:/bin:/unrelated/erts-17.1/bin"

  setup %{tmp_dir: directory} do
    root = Path.join(directory, "release")
    runtime = Path.join(directory, "runtime")
    bindir = Path.join(directory, "custom-erts/bin")

    parent = %{
      "RELEASE_ROOT" => root,
      "RELEASE_COOKIE" => "parent-cookie",
      "RELEASE_NAME" => "parent-release",
      "RELEASE_NODE" => "parent-node",
      "RELEASE_VM_ARGS" => "parent-vm-args",
      "RELEASE_TMP" => "parent-tmp",
      "RELEASE_CUSTOM_SETTING" => "parent-custom",
      "BINDIR" => bindir,
      "ROOTDIR" => runtime,
      "PATH" =>
        Enum.join(
          [
            bindir,
            root <> "/bin",
            runtime <> "/bin",
            root <> "/erts-17.1/bin",
            runtime <> "/erts-16.0/bin",
            @clean_path
          ],
          ":"
        ),
      "CXW_KEEP" => "keep-parent"
    }

    keys = Map.keys(parent) ++ ["RELEASE_NEW_OVERRIDE"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env(parent)
    System.delete_env("RELEASE_NEW_OVERRIDE")

    binary = Path.join(directory, "fake_codex")
    report = Path.join(directory, "child-env")

    report_commands =
      Enum.map_join(keys, "\n", fn key ->
        ~s(printf '%s\\n' "#{key}=${#{key}-#{@unset}}")
      end)

    File.write!(binary, """
    #!/bin/sh
    {
    #{report_commands}
    } > "$CXW_ENV_REPORT"
    printf '%s\\n' '{"type":"thread.started","thread_id":"release-probe","text":"codex exec fork"}'
    printf '%s\\n' '{"type":"turn.completed","usage":{}}'
    """)

    File.chmod!(binary, 0o755)

    expected =
      Map.new(keys, fn
        "PATH" -> {"PATH", @clean_path}
        "CXW_KEEP" -> {"CXW_KEEP", "keep-parent"}
        key -> {key, @unset}
      end)

    %{binary: binary, report: report, parent: parent, expected: expected}
  end

  for runner <- [Runner.Port, Runner.Forcola] do
    @runner runner

    describe "#{inspect(runner)}" do
      test "scrubs every command builder's execute and stream paths", context do
        config = config(context, @runner)

        for command <- builders(), operation <- [:execute, :stream] do
          assert_child(context, fn -> run_builder(command, operation, config) end)
        end
      end

      test "scrubs fresh and resumed session send and stream paths", context do
        config = config(context, @runner)

        for session_id <- [nil, "release-probe"] do
          session = %{Session.new(config) | session_id: session_id}

          assert_child(context, fn ->
            assert {:ok, _session, result} = Session.send(session, "prompt")
            {:ok, result}
          end)

          assert_child(context, fn ->
            {_session, stream} = Session.stream(session, "prompt")
            consume(stream)
          end)
        end
      end

      test "scrubs every Commands module and each direct runner call", context do
        config = config(context, @runner)

        for call <- command_calls(config), do: assert_child(context, call)
      end

      test "scrubs raw commands and the fork capability probe", context do
        assert_child(context, fn -> CodexWrapper.raw(["anything"], opts(context, @runner)) end)

        assert_child(context, fn ->
          assert ExecFork.supported?(config(context, @runner))
          {:ok, :supported}
        end)
      end

      test "explicit names override removals while explicit PATH is scrubbed", context do
        overrides = [
          {"BINDIR", "caller-bindir"},
          {"ROOTDIR", "caller-rootdir"},
          {"RELEASE_ROOT", "caller-release-root"},
          {"RELEASE_COOKIE", "caller-cookie"},
          {"RELEASE_NEW_OVERRIDE", "caller-new"},
          {"PATH", context.parent["PATH"] <> ":/caller/bin"}
        ]

        expected =
          context.expected
          |> Map.merge(Map.new(overrides))
          |> Map.put("PATH", @clean_path <> ":/caller/bin")

        context = %{context | expected: expected}
        config = config(context, @runner, env: overrides)

        for operation <- [:execute, :stream] do
          assert_child(context, fn -> run_builder(Exec.new("prompt"), operation, config) end)
        end
      end

      test "inherit reaches convenience execute and stream paths unchanged", context do
        context = %{context | expected: Map.put(context.parent, "RELEASE_NEW_OVERRIDE", @unset)}
        opts = opts(context, @runner, release_env: :inherit)

        calls = [
          fn -> CodexWrapper.exec("prompt", opts) end,
          fn -> CodexWrapper.exec_json("prompt", opts) end,
          fn -> CodexWrapper.stream("prompt", opts) |> consume() end,
          fn -> CodexWrapper.review(opts) end,
          fn -> CodexWrapper.raw(["anything"], opts) end
        ]

        for call <- calls, do: assert_child(context, call)
      end

      test "without RELEASE_ROOT execute and stream preserve the environment", context do
        System.delete_env("RELEASE_ROOT")

        expected =
          context.parent
          |> Map.put("RELEASE_ROOT", @unset)
          |> Map.put("RELEASE_NEW_OVERRIDE", @unset)

        context = %{context | expected: expected}
        config = config(context, @runner)

        for operation <- [:execute, :stream] do
          assert_child(context, fn -> run_builder(Exec.new("prompt"), operation, config) end)
        end
      end

      test "reads the release environment after config and stream construction", context do
        System.delete_env("RELEASE_ROOT")
        config = config(context, @runner)
        command = Exec.new("prompt")
        stream = Exec.stream(command, config)
        System.put_env("RELEASE_ROOT", context.parent["RELEASE_ROOT"])

        assert_child(context, fn -> Exec.execute(command, config) end)
        assert_child(context, fn -> consume(stream) end)
      end
    end
  end

  test "Forcola observed and evidenced callbacks scrub all command builders", context do
    config = config(context, Runner.Forcola)

    for command <- builders(), observer <- [:session_observer, :execution_observer] do
      options = [{observer, {self(), make_ref()}}]
      module = command.__struct__
      assert_child(context, fn -> module.execute(command, config, options) end)
    end
  end

  test "Forcola replacement environment does not inject the parent's PATH" do
    assert {:ok, "CXW_KEEP=explicit"} =
             CodexWrapper.raw([],
               binary: "/usr/bin/env",
               runner: Runner.Forcola,
               runner_options: [env_mode: :replace],
               timeout: 10_000,
               env: [{"CXW_KEEP", "explicit"}]
             )
  end

  defp builders do
    [
      Exec.new("prompt"),
      ExecResume.new() |> ExecResume.session_id("release-probe") |> ExecResume.prompt("prompt"),
      Review.new(),
      ExecFork.new("release-probe")
    ]
  end

  defp command_calls(config) do
    [
      fn -> Commands.Apply.execute(config, "task") end,
      fn -> Commands.Archive.archive(config, "release-probe") end,
      fn -> Commands.Archive.unarchive(config, "release-probe") end,
      fn -> Commands.Archive.delete(config, "release-probe", confirm: true) end,
      fn -> Commands.Auth.login(config) end,
      fn -> Commands.Auth.logout(config) end,
      fn -> Commands.Auth.status(config) end,
      fn -> Commands.Completion.generate(config) end,
      fn -> Commands.Doctor.execute(Commands.Doctor.new(), config) end,
      fn -> Commands.Features.list(config) end,
      fn -> Commands.Features.enable(config, "feature") end,
      fn -> Commands.Features.disable(config, "feature") end,
      fn -> Commands.Mcp.list(config) end,
      fn -> Commands.Mcp.get(config, "server") end,
      fn -> Commands.Mcp.add(config, "server", :stdio, command: "server") end,
      fn -> Commands.Mcp.add(config, "server", :http, url: "http://example.invalid") end,
      fn -> Commands.Mcp.remove(config, "server") end,
      fn -> Commands.Mcp.login(config, "server") end,
      fn -> Commands.Mcp.logout(config, "server") end,
      fn -> Commands.McpServer.start(config) end,
      fn -> Commands.Sandbox.execute(Commands.Sandbox.new("echo"), config) end,
      fn -> Commands.Version.execute(config) end
    ]
  end

  defp run_builder(command, :execute, config),
    do: command.__struct__.execute(command, config)

  defp run_builder(command, :stream, config),
    do: command.__struct__.stream(command, config) |> consume()

  defp consume(stream) do
    events = Enum.to_list(stream)
    assert [%CodexWrapper.JsonLineEvent{}, %CodexWrapper.JsonLineEvent{}] = events
    {:ok, events}
  end

  defp assert_child(context, call) do
    File.rm(context.report)
    assert {:ok, _} = call.()

    actual =
      context.report
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        {key, value}
      end)

    assert actual == context.expected
  end

  defp config(context, runner, overrides \\ []),
    do: Config.new(opts(context, runner, overrides))

  defp opts(context, runner, overrides \\ []) do
    [binary: context.binary, runner: runner, timeout: 10_000]
    |> Keyword.merge(overrides)
    |> Keyword.put(:env, [{"CXW_ENV_REPORT", context.report} | Keyword.get(overrides, :env, [])])
  end
end
