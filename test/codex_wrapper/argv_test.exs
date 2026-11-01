defmodule CodexWrapper.ArgvTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Argv, Config, Exec, ExecutionObservation, StreamError}

  @moduletag :tmp_dir

  test "counts UTF-8 bytes and the terminating NUL for individual arguments" do
    limits = %{total: 100_000, string: 5}
    assert :ok = Argv.validate("sh", ["éé"], [env_mode: :replace], limits)

    assert {:error, {:argument_list_too_long, %{kind: :argument, bytes: 6, limit: 5}}} =
             Argv.validate("sh", ["ééx"], [env_mode: :replace], limits)
  end

  test "many small arguments can exceed the aggregate limit" do
    limits = %{total: 32_768, string: 131_072}

    assert {:error, {:argument_list_too_long, %{kind: :total}}} =
             Argv.validate("sh", List.duplicate("", 4_000), [env_mode: :replace], limits)
  end

  test "environment entries count and repeated updates use their final value" do
    limits = %{total: 100_000, string: 20}
    huge = String.duplicate("secret", 20)

    assert {:error, {:argument_list_too_long, %{kind: :environment}}} =
             Argv.validate("sh", [], [env_mode: :replace, env: [{"KEY", huge}]], limits)

    assert :ok =
             Argv.validate(
               "sh",
               [],
               [env_mode: :replace, env: [{"KEY", huge}, {"KEY", false}]],
               limits
             )
  end

  test "rejects NUL without returning argument contents" do
    assert {:error, {:invalid_argument, 1}} = Argv.validate("sh", ["private\0value"], [])
  end

  for runner <- [CodexWrapper.Runner.Port, CodexWrapper.Runner.Forcola] do
    @runner runner
    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "#{inspect(runner)} rejects oversized argv before the target starts", %{tmp_dir: dir} do
      {binary, marker} = marker_cli(dir)
      # Individually small strings also exercise the aggregate limit on Linux.
      args = List.duplicate(String.duplicate("x", 16_384), div(Argv.limits().total, 16_384) + 1)

      assert {:error, {:argument_list_too_long, %{kind: :total}}} =
               @runner.run(binary, args, [], 5_000)

      assert [{:error, {:argument_list_too_long, %{kind: :total}}}] =
               @runner.stream_lines(binary, args, [], 5_000) |> Enum.to_list()

      refute File.exists?(marker)
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "#{inspect(runner)} rejects a large compatibility prompt with a typed error", %{
      tmp_dir: dir
    } do
      {binary, marker} = marker_cli(dir)
      prompt = String.duplicate("private", div(Argv.limits().total, 7) + 1)
      exec = Exec.new(prompt) |> Exec.prompt_input(:argv)
      config = Config.new(binary: binary, runner: @runner)

      assert {:error, {:argument_list_too_long, details}} = Exec.execute(exec, config)
      assert details.kind in [:argument, :total]
      refute inspect(details) =~ "private"

      assert [%StreamError{reason: {:argument_list_too_long, _}}] =
               Exec.stream(exec, config) |> Enum.to_list()

      refute File.exists?(marker)
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "#{inspect(runner)} enforces the Linux per-string ceiling", %{tmp_dir: dir} do
      if :os.type() == {:unix, :linux} do
        {binary, marker} = marker_cli(dir)
        limit = Argv.limits().string

        assert {:error, {:argument_list_too_long, %{kind: :argument, limit: ^limit}}} =
                 @runner.run(binary, [String.duplicate("x", limit)], [], 5_000)

        refute File.exists?(marker)
      end
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "#{inspect(runner)} rejects oversized environment before the target starts", %{
      tmp_dir: dir
    } do
      {binary, marker} = marker_cli(dir)
      private = String.duplicate("private", div(Argv.limits().total, 7) + 1)
      opts = [env: [{"PROMPT_TEST_ENV", private}]]

      assert {:error, {:argument_list_too_long, details}} =
               @runner.run(binary, [], opts, 5_000)

      assert details.kind in [:environment, :total]
      refute inspect(details) =~ "private"

      assert [{:error, {:argument_list_too_long, _}}] =
               @runner.stream_lines(binary, [], opts, 5_000) |> Enum.to_list()

      refute File.exists?(marker)
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "#{inspect(runner)} rejects an argument containing NUL before spawning", %{tmp_dir: dir} do
      {binary, marker} = marker_cli(dir)

      assert {:error, {:invalid_argument, 1}} =
               @runner.run(binary, ["private\0value"], [], 5_000)

      assert [{:error, {:invalid_argument, 1}}] =
               @runner.stream_lines(binary, ["private\0value"], [], 5_000) |> Enum.to_list()

      refute File.exists?(marker)
    end
  end

  @tag :forcola
  test "observed and evidenced failures retain pre-spawn argument errors", %{tmp_dir: dir} do
    {binary, marker} = marker_cli(dir)
    prompt = String.duplicate("x", Argv.limits().total)
    exec = Exec.new(prompt) |> Exec.prompt_input(:argv)
    config = Config.new(binary: binary, runner: :forcola)
    reference = make_ref()

    assert {:error, {:argument_list_too_long, _}} =
             Exec.execute(exec, config, session_observer: {self(), reference})

    assert {:error, {:argument_list_too_long, _}} =
             Exec.execute(exec, config, execution_observer: {self(), reference})

    assert_receive {^reference,
                    %ExecutionObservation{
                      outcome: {:error, {:argument_list_too_long, _}},
                      termination: :pre_spawn,
                      child_status: nil
                    }}

    refute File.exists?(marker)
  end

  defp marker_cli(dir) do
    path = Path.join(dir, "cli")
    marker = Path.join(dir, "spawned")
    File.write!(path, "#!/bin/sh\n: > \"$(dirname \"$0\")/spawned\"\n")
    File.chmod!(path, 0o700)
    {path, marker}
  end
end
