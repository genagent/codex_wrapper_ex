defmodule CodexWrapper.ChildEnvTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{ChildEnv, Config}

  @parent %{
    "RELEASE_ROOT" => "/srv/release",
    "ROOTDIR" => "/srv/runtime",
    "BINDIR" => "/custom/erts/bin",
    "RELEASE_COOKIE" => "host-cookie",
    "RELEASE_NODE" => "host-node",
    "RELEASE_FUTURE_OPTION" => "host-option",
    "HOME" => "/home/app",
    "PATH" => "/srv/release/erts-17.1.1/bin:/srv/release/bin:/usr/bin:/bin"
  }

  test "scrubs all release names and boot variables without copying unrelated variables" do
    assert Map.new(ChildEnv.release_scrub(@parent)) == %{
             "RELEASE_ROOT" => false,
             "ROOTDIR" => false,
             "BINDIR" => false,
             "RELEASE_COOKIE" => false,
             "RELEASE_NODE" => false,
             "RELEASE_FUTURE_OPTION" => false,
             "PATH" => "/usr/bin:/bin"
           }
  end

  test "matches whole PATH entries under both roots and the explicit bindir" do
    removed = [
      "/custom/erts/bin",
      "/srv/runtime/bin",
      "/srv/release/bin",
      "/srv/runtime/erts-15.2/bin",
      "/srv/release/erts-17.1.1/bin"
    ]

    kept = [
      "",
      "/usr/local/bin",
      "/srv/release-other/bin",
      "/prefix/srv/release/bin",
      "/srv/release/binary",
      "/srv/release/bin/tools",
      "/srv/release/erts-/bin",
      "/srv/release/erts-17/lib/bin",
      "/srv/release/nested/erts-17/bin",
      "/srv/release/erts-17/bin/tools",
      "/custom/erts/binary",
      "/usr/local/bin",
      ""
    ]

    parent = Map.put(@parent, "PATH", Enum.join(removed ++ kept ++ removed, ":"))
    assert Map.new(ChildEnv.release_scrub(parent))["PATH"] == Enum.join(kept, ":")
  end

  test "root paths with a trailing slash and the filesystem root produce exact bin entries" do
    parent = %{
      "RELEASE_ROOT" => "/release/",
      "ROOTDIR" => "/",
      "PATH" => "/release/bin:/release/erts-17/bin:/bin:/erts-15/bin:/usr/bin"
    }

    assert Map.new(ChildEnv.release_scrub(parent))["PATH"] == "/usr/bin"
  end

  test "empty release markers do not remove relative bin or empty PATH components" do
    parent = %{
      "RELEASE_ROOT" => "",
      "ROOTDIR" => "",
      "BINDIR" => "",
      "PATH" => ":bin:erts-17/bin:/bin:"
    }

    scrub = Map.new(ChildEnv.release_scrub(parent))
    assert scrub["RELEASE_ROOT"] == false
    assert scrub["PATH"] == parent["PATH"]
  end

  test "absent PATH is not added, and boot names are removed even if absent" do
    assert Map.new(ChildEnv.release_scrub(%{"RELEASE_ROOT" => "/release"})) == %{
             "RELEASE_ROOT" => false,
             "BINDIR" => false,
             "ROOTDIR" => false
           }
  end

  test "empty PATH and a PATH consisting entirely of release entries stay empty" do
    for path <- ["", "/srv/release/bin:/custom/erts/bin"] do
      assert Map.new(ChildEnv.release_scrub(Map.put(@parent, "PATH", path)))["PATH"] == ""
    end
  end

  test "does nothing outside a release even when other boot variables exist" do
    parent = Map.delete(@parent, "RELEASE_ROOT")
    overrides = [{"ROOTDIR", "/child"}, {"PATH", @parent["PATH"]}]
    assert ChildEnv.release_scrub(parent) == []
    assert ChildEnv.normalize(overrides, parent) == overrides
  end

  test "inherit opts out of both variable removal and PATH filtering" do
    overrides = [{"RELEASE_COOKIE", "child"}, {"PATH", @parent["PATH"]}]
    assert ChildEnv.normalize(overrides, @parent, :inherit) == overrides
    assert ChildEnv.normalize([], @parent, :inherit) == []
  end

  test "caller values override removals, with the last value for each name winning" do
    overrides = [
      {"RELEASE_COOKIE", "child-cookie"},
      {"RELEASE_NODE", nil},
      {"RELEASE_NODE", "child-node"},
      {"ROOTDIR", "/child/root"},
      {"BINDIR", "/child/bin"},
      {"HOME", "/home/child"}
    ]

    env = Map.new(ChildEnv.normalize(overrides, @parent))
    assert env["RELEASE_COOKIE"] == "child-cookie"
    assert env["RELEASE_NODE"] == "child-node"
    assert env["ROOTDIR"] == "/child/root"
    assert env["BINDIR"] == "/child/bin"
    assert env["HOME"] == "/home/child"
    assert env["RELEASE_ROOT"] == false
  end

  test "explicit PATH is scrubbed against parent markers even when those markers are overridden" do
    overrides = [
      {"PATH", "/discarded"},
      {"RELEASE_ROOT", "/child"},
      {"ROOTDIR", "/child/runtime"},
      {"BINDIR", "/child/bin"},
      {"PATH", "/srv/release/bin:/child/bin:/custom/erts/bin:/usr/bin"}
    ]

    assert Map.new(ChildEnv.normalize(overrides, @parent))["PATH"] == "/child/bin:/usr/bin"
  end

  test "explicit PATH removal remains a removal" do
    for unset <- [false, nil] do
      assert Map.new(ChildEnv.normalize([{"PATH", unset}], @parent))["PATH"] == false
    end
  end

  test "validates and normalizes map and charlist overrides" do
    assert Map.new(ChildEnv.normalize(%{"RELEASE_COOKIE" => nil}, @parent))["RELEASE_COOKIE"] ==
             false

    assert Map.new(ChildEnv.normalize([{~c"PATH", ~c"/srv/release/bin:/bin"}], @parent))["PATH"] ==
             "/bin"

    assert_raise ArgumentError, fn -> ChildEnv.normalize([{"PATH", 1}], @parent) end
  end

  test "config defaults and direct structs scrub; only explicit inherit disables it" do
    assert Config.new().release_env == :scrub
    assert %Config{}.release_env == :scrub
    assert Config.new(release_env: :inherit).release_env == :inherit

    for mode <- [nil, false, :other, "scrub"] do
      assert_raise ArgumentError, ~r/release_env/, fn -> Config.new(release_env: mode) end

      assert_raise ArgumentError, ~r/release_env/, fn ->
        Config.cmd_opts(%Config{release_env: mode})
      end
    end
  end
end
