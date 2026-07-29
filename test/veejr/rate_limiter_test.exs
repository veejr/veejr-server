defmodule Veejr.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Veejr.RateLimiter

  setup do
    RateLimiter.reset()
    on_exit(&RateLimiter.reset/0)
    :ok
  end

  describe "check/4" do
    test "allows requests up to the limit and rejects the next one" do
      key = unique_key()

      for _ <- 1..3 do
        assert :ok = RateLimiter.check(:login, key, 3, :timer.minutes(1))
      end

      assert {:error, retry_after} = RateLimiter.check(:login, key, 3, :timer.minutes(1))
      assert retry_after > 0
    end

    test "keys are independent" do
      a = unique_key()
      b = unique_key()

      assert :ok = RateLimiter.check(:login, a, 1, :timer.minutes(1))
      assert {:error, _} = RateLimiter.check(:login, a, 1, :timer.minutes(1))

      # b has its own budget and is unaffected by a exhausting theirs.
      assert :ok = RateLimiter.check(:login, b, 1, :timer.minutes(1))
    end

    test "buckets are independent for the same key" do
      key = unique_key()

      assert :ok = RateLimiter.check(:login, key, 1, :timer.minutes(1))
      assert {:error, _} = RateLimiter.check(:login, key, 1, :timer.minutes(1))
      assert :ok = RateLimiter.check(:upload, key, 1, :timer.minutes(1))
    end

    test "the window expires and the budget returns" do
      key = unique_key()

      assert :ok = RateLimiter.check(:login, key, 1, 50)
      assert {:error, _} = RateLimiter.check(:login, key, 1, 50)

      # Wait out the fixed window rather than assuming a boundary.
      Process.sleep(120)
      assert :ok = RateLimiter.check(:login, key, 1, 50)
    end

    test "retry_after never advertises zero seconds" do
      key = unique_key()
      assert :ok = RateLimiter.check(:login, key, 1, 50)
      assert {:error, retry_after} = RateLimiter.check(:login, key, 1, 50)
      assert retry_after >= 1
    end
  end

  describe "unidentifiable callers" do
    test "fail open rather than sharing one bucket" do
      # Bucketing every caller without a resolvable address together would let
      # any one of them lock out the others.
      for key <- [nil, "", "unknown"] do
        for _ <- 1..10 do
          assert :ok = RateLimiter.check(:login, key, 1, :timer.minutes(1))
        end
      end
    end
  end

  describe "configuration" do
    test "check/2 uses the configured bucket limit" do
      key = unique_key()
      original = Application.get_env(:veejr, :rate_limits)

      Application.put_env(
        :veejr,
        :rate_limits,
        Keyword.merge(original, login: {2, :timer.minutes(1)})
      )

      on_exit(fn -> Application.put_env(:veejr, :rate_limits, original) end)

      assert :ok = RateLimiter.check(:login, key)
      assert :ok = RateLimiter.check(:login, key)
      assert {:error, _} = RateLimiter.check(:login, key)
    end

    test "an unknown bucket is not limited" do
      key = unique_key()

      for _ <- 1..50 do
        assert :ok = RateLimiter.check(:no_such_bucket, key)
      end
    end

    test "enabled: false disables limiting entirely" do
      key = unique_key()
      original = Application.get_env(:veejr, :rate_limits)

      Application.put_env(:veejr, :rate_limits, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:veejr, :rate_limits, original) end)

      for _ <- 1..20 do
        assert :ok = RateLimiter.check(:login, key, 1, :timer.minutes(1))
      end
    end
  end

  defp unique_key, do: "key-#{System.unique_integer([:positive])}"
end
