defmodule VeejrWeb.RateLimitTest do
  @moduledoc """
  End-to-end checks that the router actually budgets the surfaces
  `docs/REIMPLEMENTATION_SPEC.md` §17 requires.
  """
  use VeejrWeb.ConnCase, async: false

  alias Veejr.RateLimiter

  setup do
    original = Application.get_env(:veejr, :rate_limits)
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:veejr, :rate_limits, original)
      RateLimiter.reset()
    end)

    {:ok, original: original}
  end

  defp set_limit(original, bucket, limit) do
    Application.put_env(
      :veejr,
      :rate_limits,
      Keyword.merge(original, [{bucket, {limit, :timer.minutes(1)}}])
    )
  end

  # Each request needs a distinct source address or it shares the previous
  # test's bucket; ConnCase always presents 127.0.0.1 otherwise.
  defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

  describe "POST /api/v1/auth/login" do
    test "returns 429 with the documented error shape once the budget is spent",
         %{conn: conn, original: original} do
      set_limit(original, :login, 2)
      body = %{"identifier" => "nobody@example.test", "password" => "wrong", "device" => %{}}

      for _ <- 1..2 do
        conn = post(from_ip(build_conn(), {203, 0, 113, 10}), ~p"/api/v1/auth/login", body)
        refute conn.status == 429
      end

      conn = post(from_ip(conn, {203, 0, 113, 10}), ~p"/api/v1/auth/login", body)

      assert conn.status == 429
      assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn, 429)
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    test "a different client keeps its own budget", %{original: original} do
      set_limit(original, :login, 1)
      body = %{"identifier" => "nobody@example.test", "password" => "wrong", "device" => %{}}

      post(from_ip(build_conn(), {203, 0, 113, 20}), ~p"/api/v1/auth/login", body)
      spent = post(from_ip(build_conn(), {203, 0, 113, 20}), ~p"/api/v1/auth/login", body)
      assert spent.status == 429

      fresh = post(from_ip(build_conn(), {203, 0, 113, 21}), ~p"/api/v1/auth/login", body)
      refute fresh.status == 429
    end
  end

  describe "GET /api/directory/:username" do
    test "enumeration is budgeted", %{original: original} do
      set_limit(original, :directory, 2)

      for _ <- 1..2 do
        conn = get(from_ip(build_conn(), {203, 0, 113, 30}), ~p"/api/directory/someone")
        refute conn.status == 429
      end

      conn = get(from_ip(build_conn(), {203, 0, 113, 30}), ~p"/api/directory/someone")
      assert conn.status == 429
      assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn, 429)
    end
  end

  describe "POST /api/v1/auth/magic-link" do
    test "mail-sending requests are budgeted separately from password attempts",
         %{original: original} do
      Application.put_env(
        :veejr,
        :rate_limits,
        Keyword.merge(original,
          magic_link: {1, :timer.minutes(1)},
          login: {100, :timer.minutes(1)}
        )
      )

      body = %{"identifier" => "nobody@example.test"}

      first = post(from_ip(build_conn(), {203, 0, 113, 40}), ~p"/api/v1/auth/magic-link", body)
      refute first.status == 429

      second = post(from_ip(build_conn(), {203, 0, 113, 40}), ~p"/api/v1/auth/magic-link", body)
      assert second.status == 429

      # The login bucket is untouched by magic-link spending.
      login =
        post(from_ip(build_conn(), {203, 0, 113, 40}), ~p"/api/v1/auth/login", %{
          "identifier" => "nobody@example.test",
          "password" => "wrong",
          "device" => %{}
        })

      refute login.status == 429
    end
  end

  describe "POST /users/log-in" do
    test "the browser login form is budgeted and answers in plain text",
         %{original: original} do
      set_limit(original, :login, 1)
      body = %{"user" => %{"identifier" => "nobody@example.test", "password" => "wrong"}}

      first = post(from_ip(build_conn(), {203, 0, 113, 50}), ~p"/users/log-in", body)
      refute first.status == 429

      second = post(from_ip(build_conn(), {203, 0, 113, 50}), ~p"/users/log-in", body)
      assert second.status == 429
      assert response_content_type(second, :text) =~ "text/plain"
      assert response(second, 429) =~ "Too many requests"
    end
  end

  describe "federation endpoints" do
    test "are budgeted before signature verification", %{original: original} do
      set_limit(original, :federation, 2)

      request = fn ->
        build_conn()
        |> from_ip({203, 0, 113, 60})
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-veejr-authority", "peer.example")
        |> post(~p"/api/federation/notify", %{})
      end

      for _ <- 1..2, do: refute(request.().status == 429)
      assert request.().status == 429
    end

    test "one noisy peer does not exhaust another peer's budget", %{original: original} do
      set_limit(original, :federation, 1)

      request = fn authority ->
        build_conn()
        |> from_ip({203, 0, 113, 70})
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-veejr-authority", authority)
        |> post(~p"/api/federation/notify", %{})
      end

      refute request.("noisy.example").status == 429
      assert request.("noisy.example").status == 429

      # Same source address, different authority: still has its own budget.
      refute request.("quiet.example").status == 429
    end
  end

  describe "proxied requests" do
    test "are bucketed per client, not per proxy", %{original: original} do
      set_limit(original, :directory, 1)

      # Both requests arrive from the proxy at 127.0.0.1 but carry different
      # forwarded clients. Without x-forwarded-for handling the second would be
      # rejected, which is exactly the lockout this guards against.
      first =
        build_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.80")
        |> get(~p"/api/directory/someone")

      refute first.status == 429

      second =
        build_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.81")
        |> get(~p"/api/directory/someone")

      refute second.status == 429

      # The same forwarded client is limited normally.
      third =
        build_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.80")
        |> get(~p"/api/directory/someone")

      assert third.status == 429
    end
  end
end
