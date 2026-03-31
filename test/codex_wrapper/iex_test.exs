defmodule CodexWrapper.IExTest do
  use ExUnit.Case, async: false

  alias CodexWrapper.IEx, as: CIEx

  setup do
    CIEx.reset()
    :ok
  end

  describe "cost/0" do
    test "returns :no_session when no session active" do
      assert CIEx.cost() == :no_session
    end
  end

  describe "say/2" do
    test "returns :no_session when no session active" do
      assert CIEx.say("hello") == :no_session
    end
  end

  describe "session_id/0" do
    test "returns nil when no session active" do
      assert CIEx.session_id() == nil
    end
  end

  describe "last/0" do
    test "returns nil when no session active" do
      assert CIEx.last() == nil
    end
  end

  describe "history/0" do
    test "returns :no_session when no session active" do
      assert CIEx.history() == :no_session
    end
  end

  describe "reset/0" do
    test "clears state" do
      assert CIEx.reset() == :ok
    end
  end

  describe "resume/2" do
    test "sets up session state" do
      assert CIEx.resume("test-session-id") == :ok
      assert CIEx.session_id() == "test-session-id"
    end

    test "with options" do
      assert CIEx.resume("sid-123", working_dir: "/tmp") == :ok
      assert CIEx.session_id() == "sid-123"
    end
  end

  describe "module exports" do
    test "exports expected functions" do
      Code.ensure_loaded!(CIEx)
      assert {:chat, 2} in CIEx.__info__(:functions)
      assert {:say, 2} in CIEx.__info__(:functions)
      assert {:cost, 0} in CIEx.__info__(:functions)
      assert {:history, 0} in CIEx.__info__(:functions)
      assert {:reset, 0} in CIEx.__info__(:functions)
      assert {:session_id, 0} in CIEx.__info__(:functions)
      assert {:resume, 2} in CIEx.__info__(:functions)
      assert {:last, 0} in CIEx.__info__(:functions)
    end
  end
end
