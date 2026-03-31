defmodule CodexWrapper.ResultTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Result

  describe "from_cmd/2" do
    test "success" do
      result = Result.from_cmd({"output text\n", 0})
      assert result.stdout == "output text\n"
      assert result.stderr == ""
      assert result.exit_code == 0
      assert result.success == true
    end

    test "failure" do
      result = Result.from_cmd({"error message\n", 1})
      assert result.stdout == "error message\n"
      assert result.stderr == ""
      assert result.exit_code == 1
      assert result.success == false
    end

    test "exit code 2" do
      result = Result.from_cmd({"", 2})
      assert result.stdout == ""
      assert result.exit_code == 2
      assert result.success == false
    end
  end
end
