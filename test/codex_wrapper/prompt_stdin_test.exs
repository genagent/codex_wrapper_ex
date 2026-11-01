defmodule CodexWrapper.PromptStdinTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, Exec, ExecFork, ExecResume, JsonLineEvent, Review, Session}

  @probe Path.expand("../fixtures/fake_codex_stdin", __DIR__)
  @session_id "019b1e96-6935-7a02-a61e-325504b0b832"
  @commands [Exec, ExecResume, Review, ExecFork]

  for runner <- [CodexWrapper.Runner.Port, CodexWrapper.Runner.Forcola] do
    @runner runner

    for command_module <- @commands do
      @command_module command_module

      if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

      test "#{inspect(command_module)} execute on #{inspect(runner)} delivers a 2 MiB prompt" do
        prompt = large_prompt()
        command = command(@command_module, prompt)
        assert {:ok, result} = @command_module.execute(command, config(@runner))
        assert_stdin(report(result.stdout), prompt)
      end

      if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

      test "#{inspect(command_module)} stream on #{inspect(runner)} delivers a 2 MiB prompt" do
        prompt = large_prompt()
        command = command(@command_module, prompt)
        assert [event] = @command_module.stream(command, config(@runner)) |> Enum.to_list()
        assert_stdin(event.data, prompt)
      end

      if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

      test "#{inspect(command_module)} on #{inspect(runner)} retains argv mode and literal dash" do
        prompt = "literal 'quotes' $dollar `backticks`\nUnicode: λ"
        command = command(@command_module, prompt) |> @command_module.prompt_input(:argv)
        assert {:ok, result} = @command_module.execute(command, config(@runner))
        assert_argv(report(result.stdout), prompt)
        assert [event] = @command_module.stream(command, config(@runner)) |> Enum.to_list()
        assert_argv(event.data, prompt)

        for mode <- [:stdin, :argv] do
          literal = command(@command_module, "-") |> @command_module.prompt_input(mode)
          assert {:ok, result} = @command_module.execute(literal, config(@runner))
          assert_stdin(report(result.stdout), "-")
          assert [event] = @command_module.stream(literal, config(@runner)) |> Enum.to_list()
          assert_stdin(event.data, "-")
        end
      end
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "Session initial and resumed sends on #{inspect(runner)} use stdin" do
      prompt = large_prompt()
      session = Session.new(config(@runner))
      assert {:ok, session, result} = Session.send(session, prompt)
      assert_stdin(report(result.stdout), prompt)
      assert Session.session_id(session) == @session_id
      assert {:ok, session, result} = Session.send(session, prompt)
      assert_stdin(report(result.stdout), prompt)
      assert Session.turn_count(session) == 2
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "Session initial and resumed streams on #{inspect(runner)} use stdin" do
      prompt = large_prompt()

      for session <- [Session.new(config(@runner)), Session.resume(config(@runner), @session_id)] do
        {^session, stream} = Session.stream(session, prompt)
        assert [event] = Enum.to_list(stream)
        assert_stdin(event.data, prompt)
      end
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "Session transport defaults and per-call overrides on #{inspect(runner)}" do
      session = Session.new(config(@runner), prompt_input: :argv)
      assert {:ok, session, result} = Session.send(session, "first")
      assert_argv(report(result.stdout), "first")
      assert {:ok, session, result} = Session.send(session, "second", prompt_input: :stdin)
      assert_stdin(report(result.stdout), "second")
      {^session, stream} = Session.stream(session, "third")
      assert [event] = Enum.to_list(stream)
      assert_argv(event.data, "third")
      {^session, stream} = Session.stream(session, "fourth", prompt_input: :stdin)
      assert [event] = Enum.to_list(stream)
      assert_stdin(event.data, "fourth")
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "nil optional prompts on #{inspect(runner)} leave stdin empty" do
      for command <- [ExecResume.new(), Review.new(), ExecFork.new(@session_id)] do
        module = command.__struct__
        assert {:ok, result} = module.execute(command, config(@runner))
        data = report(result.stdout)
        assert data["stdin_bytes"] == 0
        refute "-" in data["argv"]
      end
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "convenience APIs on #{inspect(runner)} carry stdin and argv options" do
      opts = [binary: @probe, runner: @runner, timeout: 10_000]
      assert {:ok, result} = CodexWrapper.exec("convenience", opts)
      assert_stdin(report(result.stdout), "convenience")
      assert {:ok, result} = CodexWrapper.review(opts ++ [prompt: "review"])
      assert_stdin(report(result.stdout), "review")
      assert [event] = CodexWrapper.stream("stream", opts) |> Enum.to_list()
      assert_stdin(event.data, "stream")
      assert {:ok, result} = CodexWrapper.exec("argv", opts ++ [prompt_input: :argv])
      assert_argv(report(result.stdout), "argv")
    end
  end

  for command_module <- @commands do
    @command_module command_module
    @tag :forcola
    test "#{inspect(command_module)} observed and evidenced execution retain stdin" do
      prompt = large_prompt()
      command = command(@command_module, prompt)
      config = config(CodexWrapper.Runner.Forcola)
      observed_ref = make_ref()

      assert {:ok, result} =
               @command_module.execute(command, config, session_observer: {self(), observed_ref})

      assert_stdin(report(result.stdout), prompt)
      assert_receive {^observed_ref, %CodexWrapper.SessionObservation{session_id: @session_id}}
      evidence_ref = make_ref()

      assert {:ok, result} =
               @command_module.execute(command, config,
                 execution_observer: {self(), evidence_ref}
               )

      assert_stdin(report(result.stdout), prompt)

      assert_receive {^evidence_ref,
                      %CodexWrapper.ExecutionObservation{child_status: 0, termination: :exit}}
    end
  end

  defp config(runner), do: Config.new(binary: @probe, runner: runner, timeout: 10_000)

  defp command(Exec, prompt), do: Exec.new(prompt)

  defp command(ExecResume, prompt),
    do: ExecResume.new() |> ExecResume.session_id(@session_id) |> ExecResume.prompt(prompt)

  defp command(Review, prompt), do: Review.new() |> Review.prompt(prompt)
  defp command(ExecFork, prompt), do: ExecFork.new(@session_id) |> ExecFork.prompt(prompt)

  defp report(stdout) do
    [%JsonLineEvent{data: data}] = JsonLineEvent.parse_lines(stdout)
    data
  end

  defp assert_stdin(data, prompt) do
    assert List.last(data["argv"]) == "-"
    assert data["stdin_bytes"] == byte_size(prompt)
    assert data["stdin_sha256"] == digest(prompt)
    assert data["stdin_mode"] == 0o600
    assert data["stdin_links"] == 0
  end

  defp assert_argv(data, prompt) do
    assert List.last(data["argv"]) == prompt
    assert data["stdin_bytes"] == 0
  end

  defp large_prompt do
    unit = "λ prompt 'quotes' $dollar `backticks`\n"
    bytes = 2 * 1024 * 1024
    binary_part(String.duplicate(unit, div(bytes, byte_size(unit)) + 1), 0, bytes)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
