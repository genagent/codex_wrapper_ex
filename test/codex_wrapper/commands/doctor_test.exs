defmodule CodexWrapper.Commands.DoctorTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Commands.Doctor

  describe "new/0" do
    test "defaults every option to unset" do
      doctor = Doctor.new()
      assert doctor.json == false
      assert doctor.summary == false
      assert doctor.all == false
      assert doctor.no_color == false
      assert doctor.ascii == false
    end
  end

  describe "builder functions" do
    test "json/1 sets the flag" do
      assert Doctor.new() |> Doctor.json() |> Map.fetch!(:json) == true
    end

    test "summary/1 sets the flag" do
      assert Doctor.new() |> Doctor.summary() |> Map.fetch!(:summary) == true
    end

    test "all/1 sets the flag" do
      assert Doctor.new() |> Doctor.all() |> Map.fetch!(:all) == true
    end

    test "no_color/1 sets the flag" do
      assert Doctor.new() |> Doctor.no_color() |> Map.fetch!(:no_color) == true
    end

    test "ascii/1 sets the flag" do
      assert Doctor.new() |> Doctor.ascii() |> Map.fetch!(:ascii) == true
    end
  end

  describe "args/1" do
    test "emits just the subcommand when nothing is set" do
      assert Doctor.args(Doctor.new()) == ["doctor"]
    end

    test "emits each flag when set" do
      args =
        Doctor.new()
        |> Doctor.json()
        |> Doctor.summary()
        |> Doctor.all()
        |> Doctor.no_color()
        |> Doctor.ascii()
        |> Doctor.args()

      assert args == ["doctor", "--json", "--summary", "--all", "--no-color", "--ascii"]
    end

    test "omits unset flags" do
      args = Doctor.new() |> Doctor.json() |> Doctor.args()
      assert args == ["doctor", "--json"]
    end

    test "build_args/1 matches args/1" do
      doctor = Doctor.new() |> Doctor.summary()
      assert Doctor.build_args(doctor) == Doctor.args(doctor)
    end
  end

  describe "parse_output/2" do
    test "returns the trimmed output on exit 0" do
      assert Doctor.parse_output("  15 ok · 0 fail\n", 0) == {:ok, "15 ok · 0 fail"}
    end

    test "returns an error tuple on a nonzero exit" do
      assert Doctor.parse_output("boom", 1) == {:error, {:exit, 1, "boom"}}
    end
  end
end
