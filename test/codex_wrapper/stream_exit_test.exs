defmodule CodexWrapper.StreamExitTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, Exec, JsonLineEvent, StreamError}

  @moduletag :tmp_dir

  for runner <- [CodexWrapper.Runner.Port, CodexWrapper.Runner.Forcola] do
    @runner runner

    describe "Exec.stream/2 on #{inspect(runner)}" do
      test "a nonzero exit ends with an exit_status StreamError", %{tmp_dir: dir} do
        binary = fake(dir, ~s(printf '%s\\n' '{"type":"thread.started","thread_id":"t"}'; exit 2))

        assert [%JsonLineEvent{event_type: "thread.started"}, %StreamError{reason: reason}] =
                 stream(binary, @runner)

        assert reason == {:exit_status, 2}
      end

      test "a zero exit ends with no StreamError", %{tmp_dir: dir} do
        binary = fake(dir, ~s(printf '%s\\n' '{"type":"thread.started","thread_id":"t"}'))
        assert [%JsonLineEvent{event_type: "thread.started"}] = stream(binary, @runner)
      end

      test "a missing binary ends with a StreamError", %{tmp_dir: dir} do
        assert [%StreamError{reason: reason}] = stream(Path.join(dir, "missing-codex"), @runner)
        assert reason == {:exit_status, 127} or match?({:spawn, _}, reason)
      end
    end
  end

  defp stream(binary, runner) do
    config = Config.new(binary: binary, timeout: 10_000, runner: runner)
    "x" |> Exec.new() |> Exec.stream(config) |> Enum.to_list()
  end

  defp fake(dir, body) do
    path = Path.join(dir, "fake_codex")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end
end
