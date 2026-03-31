defmodule CodexWrapper.Commands.AuthTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Auth
  alias CodexWrapper.Config

  describe "login/2" do
    test "builds basic login args" do
      config = Config.new(binary: "echo")
      assert {:ok, _output} = Auth.login(config)
    end

    test "builds args with with_api_key" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Auth.login(config, with_api_key: true)
      assert output =~ "--with-api-key"
    end

    test "builds args with device_auth" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Auth.login(config, device_auth: true)
      assert output =~ "--device-auth"
    end

    test "builds args with both flags" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Auth.login(config, with_api_key: true, device_auth: true)
      assert output =~ "--with-api-key"
      assert output =~ "--device-auth"
    end
  end

  describe "logout/1" do
    test "builds logout args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Auth.logout(config)
      assert output =~ "logout"
    end
  end

  describe "status/1" do
    test "builds status args" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Auth.status(config)
      assert output =~ "login"
      assert output =~ "status"
    end
  end
end
