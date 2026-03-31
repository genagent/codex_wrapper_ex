defmodule CodexWrapper.Commands.SandboxTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Sandbox

  describe "new/2" do
    test "creates sandbox with platform and command" do
      sandbox = Sandbox.new(:macos, "ls")
      assert sandbox.platform == :macos
      assert sandbox.command == "ls"
      assert sandbox.command_args == []
    end

    test "accepts all platforms" do
      assert Sandbox.new(:macos, "cmd").platform == :macos
      assert Sandbox.new(:linux, "cmd").platform == :linux
      assert Sandbox.new(:windows, "cmd").platform == :windows
    end
  end

  describe "builder functions" do
    test "arg/2 accumulates" do
      sandbox = Sandbox.new(:macos, "ls") |> Sandbox.arg("-la") |> Sandbox.arg("/tmp")
      assert sandbox.command_args == ["-la", "/tmp"]
    end

    test "args/2 adds multiple arguments" do
      sandbox = Sandbox.new(:linux, "cat") |> Sandbox.args(["/etc/hosts", "/etc/passwd"])
      assert sandbox.command_args == ["/etc/hosts", "/etc/passwd"]
    end

    test "arg/2 and args/2 combine" do
      sandbox =
        Sandbox.new(:macos, "ls")
        |> Sandbox.arg("-la")
        |> Sandbox.args(["/tmp", "/var"])

      assert sandbox.command_args == ["-la", "/tmp", "/var"]
    end
  end

  describe "build_args/1" do
    test "macos sandbox" do
      args = Sandbox.new(:macos, "ls") |> Sandbox.arg("-la") |> Sandbox.build_args()
      assert args == ["sandbox", "macos", "--", "ls", "-la"]
    end

    test "linux sandbox" do
      args = Sandbox.new(:linux, "cat") |> Sandbox.arg("/etc/hosts") |> Sandbox.build_args()
      assert args == ["sandbox", "linux", "--", "cat", "/etc/hosts"]
    end

    test "windows sandbox" do
      args = Sandbox.new(:windows, "dir") |> Sandbox.build_args()
      assert args == ["sandbox", "windows", "--", "dir"]
    end

    test "no command args" do
      args = Sandbox.new(:macos, "whoami") |> Sandbox.build_args()
      assert args == ["sandbox", "macos", "--", "whoami"]
    end

    test "multiple command args" do
      args =
        Sandbox.new(:linux, "grep")
        |> Sandbox.args(["-r", "pattern", "/src"])
        |> Sandbox.build_args()

      assert args == ["sandbox", "linux", "--", "grep", "-r", "pattern", "/src"]
    end
  end
end
