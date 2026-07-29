defmodule CodexWrapper.Commands.ArchiveTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Archive
  alias CodexWrapper.Config

  describe "new/2" do
    test "holds the action and session" do
      command = Archive.new(:archive, "abc-123")
      assert command.action == :archive
      assert command.session == "abc-123"
    end
  end

  describe "build_args/2" do
    test "archive" do
      assert Archive.build_args(:archive, "abc-123") == ["archive", "abc-123"]
    end

    test "unarchive" do
      assert Archive.build_args(:unarchive, "abc-123") == ["unarchive", "abc-123"]
    end

    test "delete" do
      assert Archive.build_args(:delete, "abc-123") == ["delete", "abc-123"]
    end

    test "passes a session name through unchanged" do
      assert Archive.build_args(:archive, "nightly-triage") == ["archive", "nightly-triage"]
    end

    test "agrees with args/1" do
      assert Archive.build_args(:delete, "abc-123") ==
               Archive.args(Archive.new(:delete, "abc-123"))
    end
  end

  describe "delete/3" do
    test "refuses without confirm: true and does not invoke the CLI" do
      # `binary: "false"` would exit 1 if the command ran at all.
      config = Config.new(binary: "false")
      assert Archive.delete(config, "abc-123") == {:error, :confirmation_required}
    end

    test "refuses confirm: false" do
      config = Config.new(binary: "false")
      assert Archive.delete(config, "abc-123", confirm: false) == {:error, :confirmation_required}
    end

    test "refuses a truthy non-true confirm value" do
      config = Config.new(binary: "false")
      assert Archive.delete(config, "abc-123", confirm: "yes") == {:error, :confirmation_required}
    end

    test "runs when confirmed" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Archive.delete(config, "abc-123", confirm: true)
      assert output =~ "delete abc-123"
    end
  end

  describe "execution" do
    test "archive/2 invokes the archive subcommand" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Archive.archive(config, "abc-123")
      assert output =~ "archive abc-123"
    end

    test "unarchive/2 invokes the unarchive subcommand" do
      config = Config.new(binary: "echo")
      assert {:ok, output} = Archive.unarchive(config, "abc-123")
      assert output =~ "unarchive abc-123"
    end
  end

  describe "parse_output/2" do
    test "trims stdout on exit 0" do
      assert Archive.parse_output("  done\n", 0) == {:ok, "done"}
    end

    test "reports a nonzero exit" do
      assert Archive.parse_output("no such session\n", 1) ==
               {:error, {:exit, 1, "no such session\n"}}
    end
  end
end
