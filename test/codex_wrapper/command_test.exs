defmodule CodexWrapper.CommandTest do
  use ExUnit.Case, async: true

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
    def args(_), do: ["-c", "exit 1"]
    @impl true
    def parse_output(_stdout, code), do: {:error, {:exit, code}}
  end

  describe "run/3" do
    test "executes command and parses output" do
      config = Config.new(binary: "sh")
      command = %EchoCommand{message: "world"}

      assert {:ok, "world"} = Command.run(EchoCommand, command, config)
    end

    test "passes working directory" do
      config = Config.new(binary: "sh", working_dir: "/tmp")
      command = %EchoCommand{message: "test"}

      assert {:ok, "test"} = Command.run(EchoCommand, command, config)
    end

    test "handles timeout" do
      config = Config.new(binary: "sh", timeout: 50)
      assert {:error, {:timeout, 50}} = Command.run(SlowCommand, %SlowCommand{}, config)
    end

    test "handles non-zero exit code" do
      config = Config.new(binary: "sh")
      assert {:error, {:exit, 1}} = Command.run(FailCommand, %FailCommand{}, config)
    end
  end
end
