defmodule CodexWrapper.PromptStdinLifecycleTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, Exec, ExecFork, ExecResume, Review, StreamError}

  @moduletag :tmp_dir
  @probe Path.expand("../fixtures/fake_codex_stdin", __DIR__)
  @session_id "019b1e96-6935-7a02-a61e-325504b0b832"
  @timeout_ms 1_500

  for runner <- [CodexWrapper.Runner.Port, CodexWrapper.Runner.Forcola] do
    @runner runner

    for mode <- [:execute, :stream] do
      @mode mode
      if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

      test "#{inspect(runner)} #{@mode} keeps every command's prompt out of ps", %{tmp_dir: dir} do
        for module <- [Exec, ExecResume, Review, ExecFork] do
          probe_dir = Path.join(dir, inspect(module))
          File.mkdir!(probe_dir)
          marker = "private-prompt-#{System.unique_integer([:positive])}"
          prompt = marker <> " 'quotes' $dollar λ"
          command = command(module, prompt)
          config = config(@runner, probe_dir, 20_000)
          task = Task.async(fn -> consume(module, command, config, @mode) end)
          data = wait_ready(probe_dir)
          on_exit(fn -> stop_probe(probe_dir) end)

          assert List.last(data["argv"]) == "-"
          assert data["stdin_bytes"] == byte_size(prompt)
          assert data["stdin_links"] == 0
          {processes, 0} = System.cmd("ps", ["-Aww", "-o", "pid=", "-o", "args="])

          target_row =
            processes
            |> String.split("\n")
            |> Enum.find(&String.match?(&1, ~r/^\s*#{data["pid"]}\s/))

          assert target_row
          assert target_row =~ @probe
          refute processes =~ marker

          File.touch!(Path.join(probe_dir, "release"))
          assert_success(Task.await(task, 5_000), @mode)
        end
      end

      if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

      test "#{inspect(runner)} #{@mode} timeout still escalates after stdin delivery", %{
        tmp_dir: dir
      } do
        command = Exec.new("prompt before timeout")
        config = config(@runner, dir, @timeout_ms)
        task = Task.async(fn -> consume(Exec, command, config, @mode) end)
        data = wait_ready(dir)
        on_exit(fn -> stop_probe(dir) end)
        assert data["stdin_bytes"] == byte_size(command.prompt)
        assert data["stdin_links"] == 0

        assert_timeout(Task.await(task, 15_000), @mode)
        assert wait_until(fn -> not alive?(data["pid"]) end, 5_000)

        # The probe records INT/TERM and continues running. It never exits
        # voluntarily here, so its death establishes the final KILL stage.
        expected =
          if @runner == CodexWrapper.Runner.Forcola and @mode == :stream,
            do: ["TERM"],
            else: ["INT", "TERM"]

        received = signals(dir)
        assert Enum.map(received, &elem(&1, 0)) == expected

        case received do
          [{"INT", interrupt_at}, {"TERM", terminate_at}] ->
            assert terminate_at - interrupt_at >= 1.5

          [{"TERM", _}] ->
            :ok
        end
      end
    end

    if runner == CodexWrapper.Runner.Forcola, do: @tag(:forcola)

    test "#{inspect(runner)} early stream halt stops the stdin consumer", %{tmp_dir: dir} do
      command = Exec.new("prompt before halt")
      config = config(@runner, dir, 20_000)
      on_exit(fn -> stop_probe(dir) end)
      assert [event] = Exec.stream(command, config) |> Enum.take(1)
      assert event.data["stdin_links"] == 0
      assert wait_until(fn -> not alive?(event.data["pid"]) end, 5_000)
    end
  end

  defp config(runner, dir, timeout) do
    Config.new(
      binary: @probe,
      runner: runner,
      timeout: timeout,
      env: [{"STDIN_PROBE_DIR", dir}]
    )
  end

  defp command(Exec, prompt), do: Exec.new(prompt)

  defp command(ExecResume, prompt),
    do: ExecResume.new() |> ExecResume.session_id(@session_id) |> ExecResume.prompt(prompt)

  defp command(Review, prompt), do: Review.new() |> Review.prompt(prompt)
  defp command(ExecFork, prompt), do: ExecFork.new(@session_id) |> ExecFork.prompt(prompt)

  defp consume(module, command, config, :execute), do: module.execute(command, config)

  defp consume(module, command, config, :stream),
    do: module.stream(command, config) |> Enum.to_list()

  defp assert_success({:ok, result}, :execute), do: assert(result.success)
  defp assert_success([%CodexWrapper.JsonLineEvent{}], :stream), do: :ok

  defp assert_timeout({:error, {:timeout, @timeout_ms}}, :execute), do: :ok

  defp assert_timeout([%CodexWrapper.JsonLineEvent{}, %StreamError{reason: reason}], :stream),
    do: assert(reason == {:timeout, @timeout_ms})

  defp wait_ready(dir) do
    path = Path.join(dir, "ready")
    assert wait_until(fn -> File.exists?(path) end, 5_000), "stdin probe did not start"
    path |> File.read!() |> Jason.decode!()
  end

  defp signals(dir) do
    dir
    |> Path.join("signals")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name, at] = String.split(line, " ")
      {name, String.to_float(at)}
    end)
  end

  defp stop_probe(dir) do
    case File.read(Path.join(dir, "ready")) do
      {:ok, json} ->
        pid = Jason.decode!(json)["pid"]
        if alive?(pid), do: System.cmd("kill", ["-9", Integer.to_string(pid)])

      {:error, :enoent} ->
        :ok
    end
  end

  # A zombie is no longer running and cannot retain the prompt descriptor.
  defp alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)]) do
      {output, 0} ->
        status = String.trim(output)
        status != "" and not String.starts_with?(status, "Z")

      _ ->
        false
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end
end
