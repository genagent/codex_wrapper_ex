defmodule CodexWrapper.Commands.CompletionTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Completion
  alias CodexWrapper.Config

  describe "generate/2" do
    test "defaults to bash shell" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Completion.generate(config)
      assert output =~ "completion bash"
    end

    test "accepts zsh shell" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Completion.generate(config)
      assert output =~ "completion"
    end

    test "accepts all valid shells" do
      config = Config.new(binary: "echo")

      for shell <- [:bash, :zsh, :fish, :elvish, :powershell] do
        assert {:ok, output} = Completion.generate(config, shell)
        assert output =~ "completion #{shell}"
      end
    end
  end
end
