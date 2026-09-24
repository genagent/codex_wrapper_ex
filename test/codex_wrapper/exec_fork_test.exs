defmodule CodexWrapper.ExecForkTest do
  # Not async: the execution tests override the :runner application env.
  use ExUnit.Case, async: false

  alias CodexWrapper.{Config, ExecFork, JsonLineEvent, Result}

  @source "019a0000-0000-7000-8000-000000000001"
  @forked "019a0000-0000-7000-8000-000000000002"

  defmodule ScriptedRunner do
    @moduledoc false
    @behaviour CodexWrapper.Runner

    @impl true
    def run(binary, args, opts, timeout) do
      {test_pid, reply} = Application.fetch_env!(:codex_wrapper, :exec_fork_test_runner)
      send(test_pid, {:runner_run, binary, args, opts, timeout})
      reply
    end

    @impl true
    def stream_lines(binary, args, opts, timeout) do
      {test_pid, {:ok, {stdout, _code}}} =
        Application.fetch_env!(:codex_wrapper, :exec_fork_test_runner)

      send(test_pid, {:runner_stream, binary, args, opts, timeout})
      String.split(stdout, "\n", trim: true)
    end
  end

  def forward_event(event, _measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, metadata})

  describe "new/1" do
    test "sets the source session id and defaults everything else" do
      exec = ExecFork.new(@source)
      assert exec.session_id == @source
      assert exec.prompt == nil
      assert exec.model == nil
      assert exec.sandbox == nil
      assert exec.full_auto == false
      assert exec.dangerously_bypass_approvals_and_sandbox == false
      assert exec.dangerously_bypass_hook_trust == false
      assert exec.skip_git_repo_check == false
      assert exec.ephemeral == false
      assert exec.json == false
      assert exec.output_schema == nil
      assert exec.output_last_message == nil
      assert exec.images == []
      assert exec.config_overrides == []
      assert exec.enabled_features == []
      assert exec.disabled_features == []
      assert exec.strict_config == false
      assert exec.ignore_user_config == false
      assert exec.ignore_rules == false
    end
  end

  describe "args/1" do
    test "minimal args are the subcommand and the source session id" do
      assert ExecFork.args(ExecFork.new(@source)) == ["exec", "fork", @source]
    end

    test "prompt follows the session id" do
      args = @source |> ExecFork.new() |> ExecFork.prompt("try again") |> ExecFork.args()
      assert args == ["exec", "fork", @source, "try again"]
    end

    test "every supported option, in order, with positionals last" do
      args =
        @source
        |> ExecFork.new()
        |> ExecFork.prompt("branch off")
        |> ExecFork.config("model_reasoning_effort=\"low\"")
        |> ExecFork.enable("feat-a")
        |> ExecFork.disable("feat-b")
        |> ExecFork.image("/tmp/a.png")
        |> ExecFork.strict_config()
        |> ExecFork.model("gpt-5")
        |> ExecFork.dangerously_bypass_approvals_and_sandbox()
        |> ExecFork.dangerously_bypass_hook_trust()
        |> ExecFork.skip_git_repo_check()
        |> ExecFork.ephemeral()
        |> ExecFork.ignore_user_config()
        |> ExecFork.ignore_rules()
        |> ExecFork.output_schema("/tmp/schema.json")
        |> ExecFork.json()
        |> ExecFork.output_last_message("/tmp/last.txt")
        |> ExecFork.args()

      assert args == [
               "exec",
               "fork",
               "-c",
               "model_reasoning_effort=\"low\"",
               "--enable",
               "feat-a",
               "--disable",
               "feat-b",
               "--image",
               "/tmp/a.png",
               "--strict-config",
               "--model",
               "gpt-5",
               "--dangerously-bypass-approvals-and-sandbox",
               "--dangerously-bypass-hook-trust",
               "--skip-git-repo-check",
               "--ephemeral",
               "--ignore-user-config",
               "--ignore-rules",
               "--output-schema",
               "/tmp/schema.json",
               "--json",
               "--output-last-message",
               "/tmp/last.txt",
               @source,
               "branch off"
             ]
    end

    test "list options repeat" do
      args =
        @source
        |> ExecFork.new()
        |> ExecFork.image("a.png")
        |> ExecFork.image("b.png")
        |> ExecFork.config("a=1")
        |> ExecFork.config("b=2")
        |> ExecFork.args()

      assert args == [
               "exec",
               "fork",
               "-c",
               "a=1",
               "-c",
               "b=2",
               "--image",
               "a.png",
               "--image",
               "b.png",
               @source
             ]
    end
  end

  describe "arguments codex exec fork rejects are never emitted" do
    # codex-cli 0.149.0 answers each of these with `unexpected argument`.
    @rejected ["--sandbox", "--full-auto", "--profile", "--last", "--all", "--cd", "--add-dir"]

    test "sandbox/2 becomes -c sandbox_mode" do
      for {mode, value} <- [
            read_only: "read-only",
            workspace_write: "workspace-write",
            danger_full_access: "danger-full-access"
          ] do
        args = @source |> ExecFork.new() |> ExecFork.sandbox(mode) |> ExecFork.args()
        assert args == ["exec", "fork", "-c", "sandbox_mode=\"#{value}\"", @source]
      end
    end

    test "full_auto/1 becomes -c sandbox_mode=workspace-write" do
      args = @source |> ExecFork.new() |> ExecFork.full_auto() |> ExecFork.args()
      assert args == ["exec", "fork", "-c", "sandbox_mode=\"workspace-write\"", @source]
    end

    test "an explicit sandbox wins over full_auto" do
      args =
        @source
        |> ExecFork.new()
        |> ExecFork.full_auto()
        |> ExecFork.sandbox(:read_only)
        |> ExecFork.args()

      assert "sandbox_mode=\"read-only\"" in args
      refute "sandbox_mode=\"workspace-write\"" in args
    end

    test "user config overrides come before the derived sandbox_mode" do
      args =
        @source
        |> ExecFork.new()
        |> ExecFork.config("sandbox_mode=\"danger-full-access\"")
        |> ExecFork.sandbox(:read_only)
        |> ExecFork.args()

      assert args == [
               "exec",
               "fork",
               "-c",
               "sandbox_mode=\"danger-full-access\"",
               "-c",
               "sandbox_mode=\"read-only\"",
               @source
             ]
    end

    test "no rejected flag appears even with every builder option set" do
      args =
        @source
        |> ExecFork.new()
        |> ExecFork.prompt("p")
        |> ExecFork.sandbox(:workspace_write)
        |> ExecFork.full_auto()
        |> ExecFork.model("m")
        |> ExecFork.json()
        |> ExecFork.ephemeral()
        |> ExecFork.args()

      for flag <- @rejected, do: refute(flag in args, "emitted #{flag}")
    end
  end

  describe "validate/1" do
    test "accepts UUIDs and thread names" do
      assert :ok = ExecFork.validate(ExecFork.new(@source))
      assert :ok = ExecFork.validate(ExecFork.new("my-thread name"))
    end

    test "rejects missing and malformed ids" do
      for bad <- [nil, "", " ", " #{@source}", "#{@source}\n", "--last", "-x", "a\u0000b", 42] do
        assert {:error, {:invalid_session_id, ^bad}} = ExecFork.validate(ExecFork.new(bad))
      end
    end
  end

  describe "execution" do
    setup do
      previous = Application.fetch_env(:codex_wrapper, :runner)
      Application.put_env(:codex_wrapper, :runner, ScriptedRunner)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:codex_wrapper, :runner, value)
          :error -> Application.delete_env(:codex_wrapper, :runner)
        end

        Application.delete_env(:codex_wrapper, :exec_fork_test_runner)
      end)

      %{config: Config.new(binary: "codex", timeout: 1_000)}
    end

    defp script(reply),
      do: Application.put_env(:codex_wrapper, :exec_fork_test_runner, {self(), reply})

    defp jsonl(thread_id) do
      Enum.join(
        [
          "{\"type\":\"thread.started\",\"thread_id\":\"#{thread_id}\"}",
          "{\"type\":\"turn.started\"}",
          "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"ok\"}}",
          "{\"type\":\"turn.completed\"}"
        ],
        "\n"
      )
    end

    test "fork/2 returns the new session id and leaves the source untouched", %{config: config} do
      script({:ok, {jsonl(@forked), 0}})
      exec = @source |> ExecFork.new() |> ExecFork.prompt("branch")

      assert {:ok, fork} = ExecFork.fork(exec, config)
      assert fork.session_id == @forked
      assert fork.source_session_id == @source
      assert %Result{success: true, exit_code: 0} = fork.result
      assert [%JsonLineEvent{event_type: "thread.started"} | _] = fork.events
      assert exec.session_id == @source

      assert_receive {:runner_run, "codex", args, _opts, 1_000}
      assert args == ["exec", "fork", "--json", @source, "branch"]
    end

    test "fork/2 reports a non-zero exit with the result", %{config: config} do
      out = "Error: thread/fork: thread/fork failed: no rollout found for thread id #{@source}"
      script({:ok, {out, 1}})

      assert {:error, {:exit, 1, %Result{stdout: ^out, success: false}}} =
               ExecFork.fork(ExecFork.new(@source), config)
    end

    test "fork/2 errors when exit 0 carries no new session id", %{config: config} do
      script({:ok, {"{\"type\":\"turn.completed\"}", 0}})

      assert {:error, {:missing_session_id, %Result{success: true}}} =
               ExecFork.fork(ExecFork.new(@source), config)
    end

    test "timeouts come back as {:timeout, ms}", %{config: config} do
      script({:error, :timeout})
      assert {:error, {:timeout, 1_000}} = ExecFork.fork(ExecFork.new(@source), config)
      assert {:error, {:timeout, 1_000}} = ExecFork.execute(ExecFork.new(@source), config)
    end

    test "an invalid session id is rejected without spawning", %{config: config} do
      script({:ok, {jsonl(@forked), 0}})

      assert {:error, {:invalid_session_id, "--last"}} =
               ExecFork.fork(ExecFork.new("--last"), config)

      assert {:error, {:invalid_session_id, nil}} = ExecFork.execute(ExecFork.new(nil), config)
      refute_receive {:runner_run, _, _, _, _}
    end

    test "a CLI without exec fork is a typed capability error", %{config: config} do
      old_cli =
        "error: unexpected argument '#{@source}' found\n\nUsage: codex exec [OPTIONS] [PROMPT]\n"

      script({:ok, {old_cli, 2}})
      assert {:error, {:unsupported, :exec_fork}} = ExecFork.fork(ExecFork.new(@source), config)

      assert {:error, {:unsupported, :exec_fork}} =
               ExecFork.execute(ExecFork.new(@source), config)

      script({:ok, {"error: unrecognized subcommand 'fork'\n", 2}})

      assert {:error, {:unsupported, :exec_fork}} =
               ExecFork.execute(ExecFork.new(@source), config)
    end

    test "execute/2 keeps a non-zero exit as {:ok, result}", %{config: config} do
      script({:ok, {"boom", 1}})

      assert {:ok, %Result{success: false, exit_code: 1}} =
               ExecFork.execute(ExecFork.new(@source), config)
    end

    test "execute_json/2 forces --json and parses events", %{config: config} do
      script({:ok, {jsonl(@forked), 0}})

      assert {:ok, [%JsonLineEvent{event_type: "thread.started"} | _]} =
               ExecFork.execute_json(ExecFork.new(@source), config)

      assert_receive {:runner_run, "codex", args, _opts, _timeout}
      assert "--json" in args
    end

    test "stream/2 forces --json and yields events", %{config: config} do
      script({:ok, {jsonl(@forked), 0}})

      events = @source |> ExecFork.new() |> ExecFork.stream(config) |> Enum.to_list()
      assert [%JsonLineEvent{event_type: "thread.started"} = first | _] = events
      assert JsonLineEvent.get(first, "thread_id") == @forked

      assert_receive {:runner_stream, "codex", args, _opts, _timeout}
      assert "--json" in args
    end

    test "stream/2 raises on an invalid session id", %{config: config} do
      assert_raise ArgumentError, fn -> ExecFork.stream(ExecFork.new(""), config) end
    end

    test "supported?/1 reads the exec fork help", %{config: config} do
      script({:ok, {"Usage: codex exec fork [OPTIONS] <SESSION_ID> [PROMPT]\n", 0}})
      assert ExecFork.supported?(config)
      assert_receive {:runner_run, "codex", args, _opts, _timeout}
      assert Enum.take(args, -3) == ["exec", "fork", "--help"]

      script({:ok, {"Usage: codex exec [OPTIONS] [PROMPT]\n", 0}})
      refute ExecFork.supported?(config)

      script({:error, :timeout})
      refute ExecFork.supported?(config)
    end

    test "execute/2 emits an exec span tagged :exec_fork with the source id", %{config: config} do
      handler = "exec-fork-test-#{System.unique_integer()}"
      test_pid = self()

      :telemetry.attach_many(
        handler,
        [[:codex_wrapper, :exec, :start], [:codex_wrapper, :exec, :stop]],
        &__MODULE__.forward_event/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      script({:ok, {jsonl(@forked), 0}})

      assert {:ok, _} = ExecFork.fork(ExecFork.new(@source), config)

      assert_receive {:telemetry, [:codex_wrapper, :exec, :start], start}
      assert start.command == :exec_fork
      assert start.session_id == @source
      assert_receive {:telemetry, [:codex_wrapper, :exec, :stop], stop}
      assert stop.exit_code == 0
    end
  end
end
