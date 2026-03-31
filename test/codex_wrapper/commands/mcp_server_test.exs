defmodule CodexWrapper.Commands.McpServerTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.McpServer
  alias CodexWrapper.Config

  describe "start/1" do
    test "builds basic mcp-server args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = McpServer.start(config)
      assert output =~ "mcp-server"
    end
  end

  describe "start/2" do
    test "builds args with config overrides" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = McpServer.start(config, config: ["model=\"gpt-5\""])
      assert output =~ "mcp-server"
      assert output =~ "-c"
      assert output =~ "model=\"gpt-5\""
    end

    test "builds args with enable flags" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = McpServer.start(config, enable: ["web-search"])
      assert output =~ "mcp-server"
      assert output =~ "--enable"
      assert output =~ "web-search"
    end

    test "builds args with disable flags" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = McpServer.start(config, disable: ["web-search"])
      assert output =~ "mcp-server"
      assert output =~ "--disable"
      assert output =~ "web-search"
    end

    test "builds args with all options" do
      config = Config.new(binary: "echo")

      assert {:ok, output} =
               McpServer.start(config,
                 config: ["model=\"gpt-5\""],
                 enable: ["web-search"],
                 disable: ["auto-update"]
               )

      assert output =~ "mcp-server"
      assert output =~ "-c"
      assert output =~ "model=\"gpt-5\""
      assert output =~ "--enable"
      assert output =~ "web-search"
      assert output =~ "--disable"
      assert output =~ "auto-update"
    end
  end
end
