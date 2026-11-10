defmodule CodexWrapper.RetryTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, Exec, Result, Retry}

  describe "compute_delay/5" do
    test "without jitter" do
      assert Retry.compute_delay(0, 1000, 30_000, 2, false) == 1000
      assert Retry.compute_delay(1, 1000, 30_000, 2, false) == 2000
      assert Retry.compute_delay(2, 1000, 30_000, 2, false) == 4000
      assert Retry.compute_delay(3, 1000, 30_000, 2, false) == 8000
    end

    test "respects max_delay" do
      assert Retry.compute_delay(10, 1000, 5000, 2, false) == 5000
    end

    test "with jitter is bounded" do
      for _ <- 1..50 do
        delay = Retry.compute_delay(2, 1000, 30_000, 2, true)
        assert delay >= 0
        assert delay <= 4000
      end
    end
  end

  describe "module exports" do
    test "exports expected functions" do
      Code.ensure_loaded!(Retry)
      assert {:execute, 3} in Retry.__info__(:functions)
      assert {:compute_delay, 5} in Retry.__info__(:functions)
    end
  end

  describe "failed runs (#152)" do
    @describetag :tmp_dir

    # A fake codex that records each invocation and exits with `code`.
    defp failing_codex(dir, code) do
      path = Path.join(dir, "codex")
      count = Path.join(dir, "count")
      File.write!(path, "#!/bin/sh\necho x >> '#{count}'\nexit #{code}\n")
      File.chmod!(path, 0o755)
      {Config.new(binary: path), count}
    end

    defp invocations(count),
      do: count |> File.read!() |> String.split("\n", trim: true) |> length()

    test "retry_on receives a failed run and can retry it", %{tmp_dir: dir} do
      {config, count} = failing_codex(dir, 1)
      parent = self()

      retry_on = fn reply ->
        send(parent, {:retry_on, reply})
        true
      end

      assert {:ok, %Result{success: false, exit_code: 1}} =
               Retry.execute(Exec.new("x"), config,
                 max_retries: 2,
                 base_delay_ms: 1,
                 jitter: false,
                 retry_on: retry_on
               )

      assert invocations(count) == 3
      assert_received {:retry_on, {:ok, %Result{success: false}}}
    end

    test "the default predicate does not retry a failed run", %{tmp_dir: dir} do
      {config, count} = failing_codex(dir, 1)

      assert {:ok, %Result{success: false}} =
               Retry.execute(Exec.new("x"), config, base_delay_ms: 1, jitter: false)

      assert invocations(count) == 1
    end

    test "a successful run is returned without consulting retry_on", %{tmp_dir: dir} do
      {config, count} = failing_codex(dir, 0)

      assert {:ok, %Result{success: true}} =
               Retry.execute(Exec.new("x"), config, retry_on: fn _ -> flunk("called") end)

      assert invocations(count) == 1
    end
  end
end
