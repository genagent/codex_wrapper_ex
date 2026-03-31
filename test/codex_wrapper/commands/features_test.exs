defmodule CodexWrapper.Commands.FeaturesTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Features
  alias CodexWrapper.Config

  describe "list/1" do
    test "builds list args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Features.list(config)
      assert output =~ "features"
      assert output =~ "list"
    end
  end

  describe "enable/2" do
    test "builds enable args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Features.enable(config, "my-feature")
      assert output =~ "features"
      assert output =~ "enable"
      assert output =~ "my-feature"
    end
  end

  describe "disable/2" do
    test "builds disable args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Features.disable(config, "my-feature")
      assert output =~ "features"
      assert output =~ "disable"
      assert output =~ "my-feature"
    end
  end
end
