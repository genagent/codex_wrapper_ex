defmodule CodexWrapper.ConfigTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Config

  describe "new/1" do
    test "defaults" do
      config = Config.new()
      assert config.binary != nil
      assert config.working_dir == nil
      assert config.env == []
      assert config.timeout == nil
      assert config.verbose == false
    end

    test "with explicit options" do
      config = Config.new(working_dir: "/tmp", verbose: true, timeout: 5000)
      assert config.working_dir == "/tmp"
      assert config.verbose == true
      assert config.timeout == 5000
    end

    test "with explicit binary" do
      config = Config.new(binary: "/usr/local/bin/codex")
      assert config.binary == "/usr/local/bin/codex"
    end

    test "with env" do
      config = Config.new(env: [{"OPENAI_API_KEY", "sk-test"}])
      assert config.env == [{"OPENAI_API_KEY", "sk-test"}]
    end
  end

  describe "find_binary/0" do
    test "falls back to codex when not in PATH or env" do
      original = System.get_env("CODEX_CLI")
      System.delete_env("CODEX_CLI")

      binary = Config.find_binary()
      # Either finds codex in PATH or falls back to "codex"
      assert is_binary(binary)

      if original, do: System.put_env("CODEX_CLI", original)
    end

    test "uses CODEX_CLI env var when set" do
      original = System.get_env("CODEX_CLI")
      System.put_env("CODEX_CLI", "/custom/path/codex")

      assert Config.find_binary() == "/custom/path/codex"

      if original do
        System.put_env("CODEX_CLI", original)
      else
        System.delete_env("CODEX_CLI")
      end
    end
  end

  describe "base_args/1" do
    test "empty when no flags" do
      config = Config.new()
      assert Config.base_args(config) == []
    end

    test "includes verbose flag" do
      config = Config.new(verbose: true)
      assert Config.base_args(config) == ["--verbose"]
    end
  end

  describe "cmd_opts/1" do
    test "defaults include stderr_to_stdout" do
      config = Config.new()
      opts = Config.cmd_opts(config)
      assert opts == [stderr_to_stdout: true]
    end

    test "includes cd when working_dir set" do
      config = Config.new(working_dir: "/tmp")
      opts = Config.cmd_opts(config)
      assert {:cd, "/tmp"} in opts
      assert {:stderr_to_stdout, true} in opts
    end

    test "includes env when set" do
      config = Config.new(env: [{"KEY", "val"}])
      opts = Config.cmd_opts(config)
      assert {:env, [{"KEY", "val"}]} in opts
    end
  end
end
