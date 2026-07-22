defmodule CodexWrapper.CommandForcolaTest do
  # async: false -- these tests toggle the :codex_wrapper, :runner
  # application env, which is process-global.
  use ExUnit.Case, async: false

  alias CodexWrapper.{Command, Config}

  defmodule EchoCommand do
    @behaviour Command

    defstruct message: "hello"

    @impl true
    def args(%__MODULE__{message: msg}), do: ["-c", "echo #{msg}"]

    @impl true
    def parse_output(stdout, 0), do: {:ok, String.trim(stdout)}
    def parse_output(stdout, code), do: {:error, {:exit, code, stdout}}
  end

  defmodule SlowCommand do
    @behaviour Command
    defstruct []
    @impl true
    def args(_), do: ["-c", "sleep 10"]
    @impl true
    def parse_output(stdout, code), do: {:ok, {stdout, code}}
  end

  defmodule FailCommand do
    @behaviour Command
    defstruct []
    @impl true
    def args(_), do: ["-c", "exit 3"]
    @impl true
    def parse_output(_stdout, code), do: {:error, {:exit, code}}
  end

  setup do
    Application.put_env(:codex_wrapper, :runner, :forcola)

    on_exit(fn ->
      Application.delete_env(:codex_wrapper, :runner)
      Application.delete_env(:codex_wrapper, :forcola_default_timeout_ms)
    end)

    :ok
  end

  describe "run/3 with the forcola runner" do
    test "executes command and parses output" do
      config = Config.new(binary: "sh", timeout: 5_000)
      assert {:ok, "world"} = Command.run(EchoCommand, %EchoCommand{message: "world"}, config)
    end

    test "merges stderr into stdout" do
      config = Config.new(binary: "sh", timeout: 5_000)
      command = %EchoCommand{message: "oops 1>&2"}
      assert {:ok, "oops"} = Command.run(EchoCommand, command, config)
    end

    test "passes working directory" do
      config = Config.new(binary: "sh", working_dir: "/tmp", timeout: 5_000)

      command = %EchoCommand{message: "$(basename \"$PWD\")"}
      assert {:ok, "tmp"} = Command.run(EchoCommand, command, config)
    end

    test "passes environment variables" do
      config = Config.new(binary: "sh", timeout: 5_000, env: [{"CW_FORCOLA", "set"}])
      command = %EchoCommand{message: "$CW_FORCOLA"}
      assert {:ok, "set"} = Command.run(EchoCommand, command, config)
    end

    test "surfaces non-zero exit code through parse_output/2" do
      config = Config.new(binary: "sh", timeout: 5_000)
      assert {:error, {:exit, 3}} = Command.run(FailCommand, %FailCommand{}, config)
    end

    test "times out and kills the process group, reporting the effective timeout" do
      config = Config.new(binary: "sh", timeout: 100)
      assert {:error, {:timeout, 100}} = Command.run(SlowCommand, %SlowCommand{}, config)
    end

    test "falls back to the configured default timeout when config.timeout is nil" do
      Application.put_env(:codex_wrapper, :forcola_default_timeout_ms, 100)
      config = Config.new(binary: "sh")
      assert {:error, {:timeout, 100}} = Command.run(SlowCommand, %SlowCommand{}, config)
    end
  end
end
