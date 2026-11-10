defmodule CodexWrapper.Commands.QueueTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Queue
  alias CodexWrapper.Config

  @moduletag :tmp_dir

  test "args/1 sends thread and message as --flag=value" do
    assert Queue.args(Queue.new("thread-A", "-also lint")) ==
             ["queue", "--thread=thread-A", "--message=-also lint"]
  end

  test "args/1 emits each option" do
    command =
      Queue.new("t", "m",
        remote: "unix://",
        remote_auth_token_env: "TOKEN",
        model: "gpt-5",
        profile: "ci",
        local_provider: "ollama",
        cd: "/repo",
        add_dir: ["/a", "/b"],
        sandbox: :workspace_write,
        oss: true,
        approve_for_me: false,
        strict_config: true,
        dangerously_bypass_approvals_and_sandbox: true,
        dangerously_bypass_hook_trust: true,
        config: "a=1",
        enable: "x",
        disable: ["y"]
      )

    assert Queue.args(command) ==
             ["queue", "--thread=t", "--message=m", "--remote=unix://"] ++
               ["--remote-auth-token-env=TOKEN", "--model=gpt-5", "--profile=ci"] ++
               ["--local-provider=ollama", "--cd=/repo", "--add-dir=/a", "--add-dir=/b"] ++
               ["--sandbox=workspace-write", "--oss", "--strict-config"] ++
               ["--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust"] ++
               ["-c", "a=1", "--enable=x", "--disable=y"]
  end

  test "new/3 rejects bad input" do
    assert_raise ArgumentError, ~r/non-empty thread/, fn -> Queue.new("", "m") end
    assert_raise ArgumentError, ~r/non-empty thread/, fn -> Queue.new("t", nil) end

    assert_raise ArgumentError, ~r/unknown option :images/, fn ->
      Queue.new("t", "m", images: "a.png")
    end

    assert_raise ArgumentError, ~r/unknown option :worktree/, fn ->
      Queue.new("t", "m", worktree: true)
    end

    assert_raise ArgumentError, ~r/:sandbox expects/, fn ->
      Queue.new("t", "m", sandbox: :open)
    end

    assert_raise ArgumentError, ~r/invalid value/, fn -> Queue.new("t", "m", oss: "yes") end
    assert_raise ArgumentError, ~r/invalid value/, fn -> Queue.new("t", "m", add_dir: []) end
  end

  test "add/4 returns trimmed output, or the exit and output", %{tmp_dir: dir} do
    ok = Path.join(dir, "ok")
    File.write!(ok, "#!/bin/sh\necho queued\n")
    File.chmod!(ok, 0o755)
    assert Queue.add(Config.new(binary: ok), "t", "m") == {:ok, "queued"}

    bad = Path.join(dir, "bad")
    File.write!(bad, "#!/bin/sh\necho 'Error: no rollout found'\nexit 1\n")
    File.chmod!(bad, 0o755)
    assert {:error, {:exit, 1, output}} = Queue.add(Config.new(binary: bad), "t", "m")
    assert output =~ "no rollout found"
  end
end
