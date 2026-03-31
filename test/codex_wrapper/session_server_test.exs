defmodule CodexWrapper.SessionServerTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, SessionServer}

  describe "start_link/1" do
    test "initial state" do
      config = Config.new()
      {:ok, pid} = SessionServer.start_link(config: config)

      assert SessionServer.session_id(pid) == nil
      assert SessionServer.turn_count(pid) == 0
      assert SessionServer.total_cost(pid) == 0.0
      assert SessionServer.last_result(pid) == nil
      assert SessionServer.history(pid) == []
    end

    test "with exec opts" do
      config = Config.new()
      {:ok, pid} = SessionServer.start_link(config: config, exec_opts: [model: "o3"])

      session = SessionServer.get_session(pid)
      assert session.exec_opts == [model: "o3"]
    end

    test "with session_id for resume" do
      config = Config.new()
      {:ok, pid} = SessionServer.start_link(config: config, session_id: "abc-123")

      assert SessionServer.session_id(pid) == "abc-123"
    end

    test "with name registration" do
      config = Config.new()

      {:ok, _pid} =
        SessionServer.start_link(config: config, name: :test_codex_session_server)

      assert SessionServer.turn_count(:test_codex_session_server) == 0
    end

    test "child_spec for supervision" do
      config = Config.new()
      spec = SessionServer.child_spec(config: config, name: :supervised_codex_test)

      assert spec.id == SessionServer
      assert spec.start == {SessionServer, :start_link, [[config: config, name: :supervised_codex_test]]}
    end
  end

  describe "get_session/1" do
    test "returns session struct" do
      config = Config.new()
      {:ok, pid} = SessionServer.start_link(config: config)

      session = SessionServer.get_session(pid)
      assert %CodexWrapper.Session{} = session
      assert session.config == config
    end
  end
end
