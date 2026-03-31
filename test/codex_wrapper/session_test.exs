defmodule CodexWrapper.SessionTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, Session}

  describe "new/2" do
    test "creates session with config" do
      config = Config.new()
      session = Session.new(config)
      assert session.config == config
      assert session.session_id == nil
      assert session.history == []
      assert session.exec_opts == []
    end

    test "with exec opts" do
      config = Config.new()
      session = Session.new(config, model: "o3", full_auto: true)
      assert session.exec_opts == [model: "o3", full_auto: true]
    end
  end

  describe "resume/3" do
    test "sets session_id" do
      config = Config.new()
      session = Session.resume(config, "abc-123")
      assert Session.session_id(session) == "abc-123"
    end

    test "with exec opts" do
      config = Config.new()
      session = Session.resume(config, "abc-123", model: "o3")
      assert session.exec_opts == [model: "o3"]
      assert Session.session_id(session) == "abc-123"
    end
  end

  describe "session_id/1" do
    test "returns nil when no session_id" do
      config = Config.new()
      session = Session.new(config)
      assert Session.session_id(session) == nil
    end

    test "returns session_id when set" do
      config = Config.new()
      session = Session.resume(config, "abc-123")
      assert Session.session_id(session) == "abc-123"
    end
  end

  describe "turn_count/1" do
    test "starts at zero" do
      config = Config.new()
      session = Session.new(config)
      assert Session.turn_count(session) == 0
    end
  end

  describe "total_cost/1" do
    test "returns zero" do
      config = Config.new()
      session = Session.new(config)
      assert Session.total_cost(session) == 0.0
    end
  end

  describe "last_result/1" do
    test "returns nil when no turns" do
      config = Config.new()
      session = Session.new(config)
      assert Session.last_result(session) == nil
    end
  end

  describe "turns/1" do
    test "returns empty list initially" do
      config = Config.new()
      session = Session.new(config)
      assert Session.turns(session) == []
    end
  end

  describe "history/1" do
    test "aliases turns" do
      config = Config.new()
      session = Session.new(config)
      assert Session.history(session) == Session.turns(session)
    end
  end
end
