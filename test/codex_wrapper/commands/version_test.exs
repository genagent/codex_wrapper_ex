defmodule CodexWrapper.Commands.VersionTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Version
  alias CodexWrapper.Config

  @fake_codex Path.expand("../../fixtures/fake_codex.sh", __DIR__)

  describe "execute/1" do
    test "returns version map" do
      config = Config.new(binary: @fake_codex)
      assert {:ok, %{version: version, raw: raw}} = Version.execute(config)
      assert version =~ "--version"
      assert raw == version
    end
  end
end
