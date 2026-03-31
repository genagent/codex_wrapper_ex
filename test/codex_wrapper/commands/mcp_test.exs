defmodule CodexWrapper.Commands.McpTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Mcp
  alias CodexWrapper.Config

  describe "list/2" do
    test "builds basic list args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Mcp.list(config)
      assert output =~ "mcp"
      assert output =~ "list"
    end

    test "builds list args with json" do
      # echo outputs the args, not valid JSON, so this will fail JSON decode
      config = Config.new(binary: "echo")
      assert {:error, {:json_decode, _}} = Mcp.list(config, json: true)
    end
  end

  describe "get/3" do
    test "builds get args with name" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Mcp.get(config, "my-server")
      assert output =~ "mcp"
      assert output =~ "get"
      assert output =~ "my-server"
    end

    test "builds get args with json" do
      config = Config.new(binary: "echo")
      assert {:error, {:json_decode, _}} = Mcp.get(config, "my-server", json: true)
    end
  end

  describe "add/4 stdio" do
    test "builds stdio add args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Mcp.add(config, "my-server", :stdio, command: "npx")
      assert output =~ "mcp"
      assert output =~ "add"
      assert output =~ "my-server"
      assert output =~ "--"
      assert output =~ "npx"
    end

    test "builds stdio add args with command args" do
      config = Config.new(binary: "echo")

      assert {:ok, output} =
               Mcp.add(config, "srv", :stdio, command: "npx", args: ["-y", "server"])

      assert output =~ "npx"
      assert output =~ "-y"
      assert output =~ "server"
    end

    test "builds stdio add args with env" do
      config = Config.new(binary: "echo")

      assert {:ok, output} =
               Mcp.add(config, "srv", :stdio, command: "npx", env: %{"KEY" => "val"})

      assert output =~ "--env"
      assert output =~ "KEY=val"
    end
  end

  describe "add/4 http" do
    test "builds http add args" do
      config = Config.new(binary: "echo")

      assert {:ok, output} =
               Mcp.add(config, "my-server", :http, url: "http://localhost:8080")

      assert output =~ "mcp"
      assert output =~ "add"
      assert output =~ "my-server"
      assert output =~ "--url"
      assert output =~ "http://localhost:8080"
    end

    test "builds http add args with bearer token env var" do
      config = Config.new(binary: "echo")

      assert {:ok, output} =
               Mcp.add(config, "srv", :http,
                 url: "http://localhost:8080",
                 bearer_token_env_var: "MY_TOKEN"
               )

      assert output =~ "--bearer-token-env-var"
      assert output =~ "MY_TOKEN"
    end
  end

  describe "remove/2" do
    test "builds remove args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Mcp.remove(config, "my-server")
      assert output =~ "mcp"
      assert output =~ "remove"
      assert output =~ "my-server"
    end
  end
end
