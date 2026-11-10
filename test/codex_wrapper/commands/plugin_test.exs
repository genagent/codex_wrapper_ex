defmodule CodexWrapper.Commands.PluginTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Plugin
  alias CodexWrapper.Config

  @moduletag :tmp_dir

  defp args(action, target, opts \\ []), do: Plugin.args(Plugin.new(action, target, opts))

  describe "args/1" do
    test "list passes --json and its options" do
      assert args(:list, nil, marketplace: "debug", available: true) ==
               ["plugin", "list", "--json", "--marketplace=debug", "--available"]

      assert args(:list, nil, available: false) == ["plugin", "list", "--json"]
    end

    test "add and remove put the plugin after --" do
      assert args(:add, "sample@debug") == ["plugin", "add", "--json", "--", "sample@debug"]

      assert args(:remove, "-odd", marketplace: "m") ==
               ["plugin", "remove", "--json", "--marketplace=m", "--", "-odd"]
    end

    test "marketplace subcommands" do
      assert args(:marketplace_add, "https://example.com/m.git", ref: "v1", sparse: ["a", "b"]) ==
               ["plugin", "marketplace", "add", "--json", "--ref=v1", "--sparse=a", "--sparse=b"] ++
                 ["--", "https://example.com/m.git"]

      assert args(:marketplace_list, nil) == ["plugin", "marketplace", "list", "--json"]
      assert args(:marketplace_upgrade, nil) == ["plugin", "marketplace", "upgrade", "--json"]

      assert args(:marketplace_upgrade, "m") ==
               ["plugin", "marketplace", "upgrade", "--json", "--", "m"]

      assert args(:marketplace_remove, "m") ==
               ["plugin", "marketplace", "remove", "--json", "--", "m"]
    end

    test "common options" do
      assert args(:marketplace_list, nil, config: ["a=1", "b=2"], enable: "x", disable: ["y"]) ==
               ["plugin", "marketplace", "list", "--json"] ++
                 ["-c", "a=1", "-c", "b=2", "--enable=x", "--disable=y"]
    end

    test "rejects options the action does not take and bad values" do
      assert_raise ArgumentError, ~r/unknown option :available/, fn ->
        Plugin.new(:add, "p", available: true)
      end

      assert_raise ArgumentError, ~r/unknown option :ref/, fn ->
        Plugin.new(:list, nil, ref: "x")
      end

      assert_raise ArgumentError, ~r/invalid value/, fn ->
        Plugin.new(:list, nil, available: "yes")
      end

      assert_raise ArgumentError, ~r/invalid value/, fn ->
        Plugin.new(:list, nil, marketplace: 1)
      end
    end
  end

  describe "parse_output/2" do
    test "decodes JSON, after any leading warning lines" do
      assert Plugin.parse_output(~s({"installed": [], "available": []}\n), 0) ==
               {:ok, %{"installed" => [], "available" => []}}

      assert Plugin.parse_output("WARNING: something\n{\"marketplaces\": []}\n", 0) ==
               {:ok, %{"marketplaces" => []}}
    end

    test "non-JSON output and non-zero exits" do
      assert Plugin.parse_output("not json", 0) == {:error, {:json, "not json"}}
      assert Plugin.parse_output("Error: nope\n", 1) == {:error, {:exit, 1, "Error: nope\n"}}
    end
  end

  describe "running" do
    defp fake(dir, body) do
      path = Path.join(dir, "fake_codex")
      File.write!(path, "#!/bin/sh\n" <> body <> "\n")
      File.chmod!(path, 0o755)
      Config.new(binary: path)
    end

    test "list returns the decoded document", %{tmp_dir: dir} do
      config = fake(dir, ~s(printf '{"installed": [{"id": "a@b"}], "available": []}\\n'))
      assert {:ok, %{"installed" => [%{"id" => "a@b"}]}} = Plugin.list(config)
    end

    test "a non-zero exit is an error with the output", %{tmp_dir: dir} do
      config = fake(dir, "echo 'Error: plugin requires --marketplace'; exit 1")

      assert {:error, {:exit, 1, output}} = Plugin.remove(config, "x")
      assert output =~ "requires --marketplace"
    end
  end
end
