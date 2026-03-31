defmodule CodexWrapper.Commands.ApplyTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Apply

  describe "build_args/1" do
    test "produces correct args" do
      assert Apply.build_args("abc-123") == ["apply", "abc-123"]
    end

    test "with different task id" do
      assert Apply.build_args("task-456-def") == ["apply", "task-456-def"]
    end
  end
end
