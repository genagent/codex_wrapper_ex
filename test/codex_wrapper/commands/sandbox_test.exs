defmodule CodexWrapper.Commands.SandboxTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Sandbox

  describe "new/1" do
    test "creates sandbox with the command" do
      sandbox = Sandbox.new("ls")
      assert sandbox.command == "ls"
      assert sandbox.command_args == []
    end

    test "defaults every option to unset" do
      sandbox = Sandbox.new("ls")
      assert sandbox.permission_profile == nil
      assert sandbox.sandbox_state_json == nil
      assert sandbox.sandbox_state_readable_roots == []
      assert sandbox.sandbox_state_disable_network == false
      assert sandbox.cd == nil
    end
  end

  describe "new/2" do
    test "raises with a migration message for the removed platform argument" do
      assert_raise ArgumentError, ~r/no longer accepts/, fn ->
        Sandbox.new(:macos, "ls")
      end
    end

    test "names the new/1 replacement in the message" do
      error = assert_raise ArgumentError, fn -> Sandbox.new(:linux, "cat") end
      assert error.message =~ "Sandbox.new(\"cat\")"
    end
  end

  describe "builder functions" do
    test "arg/2 accumulates" do
      sandbox = Sandbox.new("ls") |> Sandbox.arg("-la") |> Sandbox.arg("/tmp")
      assert sandbox.command_args == ["-la", "/tmp"]
    end

    test "args/2 adds multiple arguments" do
      sandbox = Sandbox.new("cat") |> Sandbox.args(["/etc/hosts", "/etc/passwd"])
      assert sandbox.command_args == ["/etc/hosts", "/etc/passwd"]
    end

    test "arg/2 and args/2 combine" do
      sandbox =
        Sandbox.new("ls")
        |> Sandbox.arg("-la")
        |> Sandbox.args(["/tmp", "/var"])

      assert sandbox.command_args == ["-la", "/tmp", "/var"]
    end

    test "permission_profile/2 sets the profile" do
      sandbox = Sandbox.new("ls") |> Sandbox.permission_profile("ci")
      assert sandbox.permission_profile == "ci"
    end

    test "sandbox_state_json/2 sets the path" do
      sandbox = Sandbox.new("ls") |> Sandbox.sandbox_state_json("/tmp/state.json")
      assert sandbox.sandbox_state_json == "/tmp/state.json"
    end

    test "sandbox_state_readable_root/2 accumulates" do
      sandbox =
        Sandbox.new("ls")
        |> Sandbox.sandbox_state_readable_root("/usr/share")
        |> Sandbox.sandbox_state_readable_root("/opt")

      assert sandbox.sandbox_state_readable_roots == ["/usr/share", "/opt"]
    end

    test "sandbox_state_disable_network/1 flips the flag" do
      sandbox = Sandbox.new("ls") |> Sandbox.sandbox_state_disable_network()
      assert sandbox.sandbox_state_disable_network
    end

    test "cd/2 sets the sandboxed working directory" do
      assert Sandbox.new("ls") |> Sandbox.cd("/src") |> Map.fetch!(:cd) == "/src"
    end
  end

  describe "build_args/1" do
    test "bare command" do
      assert Sandbox.build_args(Sandbox.new("whoami")) == ["sandbox", "--", "whoami"]
    end

    test "command with args" do
      args = Sandbox.new("ls") |> Sandbox.arg("-la") |> Sandbox.build_args()
      assert args == ["sandbox", "--", "ls", "-la"]
    end

    test "multiple command args" do
      args =
        Sandbox.new("grep")
        |> Sandbox.args(["-r", "pattern", "/src"])
        |> Sandbox.build_args()

      assert args == ["sandbox", "--", "grep", "-r", "pattern", "/src"]
    end

    test "no platform subcommand is emitted" do
      args = Sandbox.build_args(Sandbox.new("ls"))
      refute "macos" in args
      refute "linux" in args
      refute "windows" in args
    end

    test "permission profile" do
      args = Sandbox.new("pytest") |> Sandbox.permission_profile("ci") |> Sandbox.build_args()
      assert args == ["sandbox", "--permission-profile", "ci", "--", "pytest"]
    end

    test "sandbox state json" do
      args =
        Sandbox.new("ls") |> Sandbox.sandbox_state_json("/tmp/s.json") |> Sandbox.build_args()

      assert args == ["sandbox", "--sandbox-state-json", "/tmp/s.json", "--", "ls"]
    end

    test "readable roots repeat the flag" do
      args =
        Sandbox.new("ls")
        |> Sandbox.sandbox_state_readable_root("/usr/share")
        |> Sandbox.sandbox_state_readable_root("/opt")
        |> Sandbox.build_args()

      assert args == [
               "sandbox",
               "--sandbox-state-readable-root",
               "/usr/share",
               "--sandbox-state-readable-root",
               "/opt",
               "--",
               "ls"
             ]
    end

    test "disable network is a bare flag" do
      args = Sandbox.new("ls") |> Sandbox.sandbox_state_disable_network() |> Sandbox.build_args()
      assert args == ["sandbox", "--sandbox-state-disable-network", "--", "ls"]
    end

    test "cd" do
      args = Sandbox.new("ls") |> Sandbox.cd("/src") |> Sandbox.build_args()
      assert args == ["sandbox", "--cd", "/src", "--", "ls"]
    end

    test "all options precede the -- separator" do
      args =
        Sandbox.new("pytest")
        |> Sandbox.permission_profile("ci")
        |> Sandbox.sandbox_state_json("/tmp/s.json")
        |> Sandbox.sandbox_state_readable_root("/usr/share")
        |> Sandbox.sandbox_state_disable_network()
        |> Sandbox.cd("/src")
        |> Sandbox.arg("-q")
        |> Sandbox.build_args()

      assert args == [
               "sandbox",
               "--permission-profile",
               "ci",
               "--sandbox-state-json",
               "/tmp/s.json",
               "--sandbox-state-readable-root",
               "/usr/share",
               "--sandbox-state-disable-network",
               "--cd",
               "/src",
               "--",
               "pytest",
               "-q"
             ]
    end

    test "a dash-leading command arg stays after the separator" do
      args = Sandbox.new("ls") |> Sandbox.arg("--color=never") |> Sandbox.build_args()
      assert List.last(args) == "--color=never"
      assert Enum.at(args, -3) == "--"
    end
  end

  describe "args/1 (Command behaviour)" do
    test "matches build_args/1" do
      sandbox = Sandbox.new("ls") |> Sandbox.permission_profile("ci") |> Sandbox.arg("-la")
      assert Sandbox.args(sandbox) == Sandbox.build_args(sandbox)
    end
  end

  describe "parse_output/2" do
    test "trims stdout on a zero exit" do
      assert Sandbox.parse_output("hello\n", 0) == {:ok, "hello"}
    end

    test "surfaces a non-zero exit with the output" do
      assert Sandbox.parse_output("boom\n", 3) == {:error, {:exit, 3, "boom\n"}}
    end
  end
end
