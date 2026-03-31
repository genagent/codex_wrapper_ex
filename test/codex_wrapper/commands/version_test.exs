defmodule CodexWrapper.Commands.VersionTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Version
  alias CodexWrapper.Config

  describe "execute/1" do
    test "returns version map" do
      config = Config.new(binary: "echo")
      assert {:ok, %{version: version, raw: raw}} = Version.execute(config)
      assert version =~ "--version"
      assert raw == version
    end
  end
end
