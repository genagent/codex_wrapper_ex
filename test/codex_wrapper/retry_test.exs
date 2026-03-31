defmodule CodexWrapper.RetryTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Retry

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
end
