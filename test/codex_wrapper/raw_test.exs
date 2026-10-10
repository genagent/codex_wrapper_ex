defmodule CodexWrapper.RawTest do
  # These tests change the process-global runner configuration.
  use ExUnit.Case, async: false

  alias CodexWrapper.Config

  defmodule FakeRunner do
    @behaviour CodexWrapper.Runner

    @impl true
    def run(binary, args, opts, timeout) do
      {test_pid, reply} = Application.fetch_env!(:codex_wrapper, :raw_test_runner)
      send(test_pid, {:runner_called, binary, args, opts, timeout})

      case reply do
        :raise_erlang_error -> raise ErlangError, original: :enoent
        result -> result
      end
    end
  end

  defmodule DefaultTimeoutRunner do
    @behaviour CodexWrapper.Runner

    @impl true
    def run(binary, args, opts, timeout), do: FakeRunner.run(binary, args, opts, timeout)

    @impl true
    def effective_timeout(timeout) do
      send(self(), {:effective_timeout_called, timeout})
      timeout || 999
    end
  end

  setup do
    previous_runner = Application.fetch_env(:codex_wrapper, :runner)
    previous_script = Application.fetch_env(:codex_wrapper, :raw_test_runner)

    on_exit(fn ->
      restore_env(:runner, previous_runner)
      restore_env(:raw_test_runner, previous_script)
    end)

    Application.put_env(:codex_wrapper, :runner, FakeRunner)
    set_reply({:ok, {"  output\n", 0}})
    :ok
  end

  test "routes through the configured runner with binary, args, options and timeout" do
    args = ["exec", "a prompt with spaces", "--json"]

    opts = [
      binary: "/nonexistent/codex-raw-must-not-run",
      working_dir: "/nonexistent/raw-working-dir",
      env: [{"RAW_TEST", "value"}],
      timeout: 123
    ]

    config = Config.new(opts)
    expected_args = Config.base_args(config) ++ args
    expected_opts = Config.cmd_opts(config)
    binary = config.binary

    assert {:ok, "output"} = CodexWrapper.raw(args, opts)
    assert_received {:runner_called, ^binary, ^expected_args, ^expected_opts, 123}
    assert expected_opts[:stderr_to_stdout] == true
    assert expected_opts[:cd] == opts[:working_dir]
    assert expected_opts[:env] == opts[:env]
    refute_received {:runner_called, _, _, _, _}
  end

  test "trims successful output" do
    set_reply({:ok, {" \t hello\n\n", 0}})

    assert {:ok, "hello"} = raw()
    assert_received {:runner_called, _, ["version"], [stderr_to_stdout: true], nil}
  end

  test "preserves output bytes and exit code on a nonzero exit" do
    output = " \t failure\n\n"
    set_reply({:ok, {output, 7}})

    assert {:error, {:exit, 7, ^output}} = raw()
    assert_received {:runner_called, _, _, _, nil}
  end

  test "reports the supplied timeout when the runner has no effective timeout callback" do
    set_reply({:error, :timeout})

    assert {:error, {:timeout, 123}} = raw(timeout: 123)
    assert_received {:runner_called, _, _, _, 123}
  end

  test "preserves nil timeout when the runner has no effective timeout callback" do
    set_reply({:error, :timeout})

    assert {:error, {:timeout, nil}} = raw()
    assert_received {:runner_called, _, _, _, nil}
  end

  test "reports the runner's substituted default timeout" do
    Application.put_env(:codex_wrapper, :runner, DefaultTimeoutRunner)
    set_reply({:error, :timeout})

    assert {:error, {:timeout, 999}} = raw()
    assert_received {:runner_called, _, _, _, nil}
    assert_received {:effective_timeout_called, nil}
  end

  test "passes an explicit timeout to the runner's effective timeout callback" do
    Application.put_env(:codex_wrapper, :runner, DefaultTimeoutRunner)
    set_reply({:error, :timeout})

    assert {:error, {:timeout, 456}} = raw(timeout: 456)
    assert_received {:runner_called, _, _, _, 456}
    assert_received {:effective_timeout_called, 456}
  end

  test "propagates other runner errors unchanged" do
    for reason <- [:enoent, {:spawn, :eacces}, {:signal, 9}, {:io, :closed}] do
      set_reply({:error, reason})

      assert {:error, ^reason} = raw()
      assert_received {:runner_called, _, _, _, nil}
    end
  end

  test "preserves the ErlangError rescue" do
    set_reply(:raise_erlang_error)

    assert {:error, {:system_cmd, %ErlangError{original: :enoent}}} = raw()
    assert_received {:runner_called, _, _, _, nil}
  end

  test "Port runs literal executable paths without shell injection or glob expansion" do
    dir = Path.join(System.tmp_dir!(), "codex-raw-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Application.put_env(:codex_wrapper, :runner, CodexWrapper.Runner.Port)

    script = """
    #!/bin/sh
    if read -r unexpected; then
      exit 9
    fi
    printf 'path-supported:%s\\n' "$1"
    printf 'stderr-supported\\n' >&2
    """

    # This competing executable exposes accidental expansion of fake*codex.
    decoy = Path.join(dir, "fake-other-codex")
    File.write!(decoy, "#!/bin/sh\nprintf 'wrong-executable\\n'\n")
    File.chmod!(decoy, 0o700)

    names = [
      "plain-codex",
      "fake codex",
      "fake 'single' \"double\" codex",
      "fake codex; touch injected; #",
      "fake$(touch substituted)`touch backtick`codex",
      "fake*codex",
      "fake?codex",
      "fake[abc]codex",
      "fake#codex<>"
    ]

    for name <- names do
      binary = Path.join(dir, name)
      File.write!(binary, script)
      File.chmod!(binary, 0o700)

      assert {:ok, "path-supported:argument with spaces ' and $literal\nstderr-supported"} =
               CodexWrapper.raw(["argument with spaces ' and $literal"],
                 binary: binary,
                 working_dir: dir,
                 timeout: 2_000
               )

      for marker <- ["injected", "substituted", "backtick"] do
        refute File.exists?(Path.join(dir, marker))
      end
    end

    assert {:ok, "path-supported:plain\nstderr-supported"} =
             CodexWrapper.raw(["plain"],
               binary: "plain-codex",
               env: [{"PATH", dir}],
               timeout: 2_000
             )
  end

  defp raw(opts \\ []) do
    CodexWrapper.raw(
      ["version"],
      Keyword.put(opts, :binary, "/nonexistent/codex-raw-must-not-run")
    )
  end

  defp set_reply(reply) do
    Application.put_env(:codex_wrapper, :raw_test_runner, {self(), reply})
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:codex_wrapper, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:codex_wrapper, key)
end
