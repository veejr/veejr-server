defmodule VeejrWeb.Plugs.RateLimit do
  @moduledoc """
  Applies `Veejr.RateLimiter` to a pipeline or route.

      plug VeejrWeb.Plugs.RateLimit, bucket: :login

  The bucket key is the resolved client address (see `Veejr.RemoteIp`). On
  rejection the response is a `429` carrying `Retry-After`, shaped as the
  documented `rate_limited` JSON error for API requests and as plain text for
  browser requests.

  Federation requests bucket on the calling instance authority when the header
  is present, so one noisy peer cannot exhaust the budget for every peer that
  happens to share an address.
  """

  import Plug.Conn

  alias Veejr.{RateLimiter, RemoteIp}

  @behaviour Plug

  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    %{bucket: bucket, by: Keyword.get(opts, :by, :ip)}
  end

  @impl true
  def call(conn, %{bucket: bucket, by: by}) do
    case RateLimiter.check(bucket, bucket_key(conn, by)) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> reject(retry_after)
        |> halt()
    end
  end

  defp bucket_key(conn, :ip), do: RemoteIp.from_conn(conn)

  defp bucket_key(conn, :federation_authority) do
    case get_req_header(conn, "x-veejr-authority") do
      [authority | _] when is_binary(authority) and authority != "" ->
        "authority:" <> String.downcase(authority)

      _ ->
        RemoteIp.from_conn(conn)
    end
  end

  defp reject(conn, retry_after) do
    if json_request?(conn) do
      VeejrWeb.Api.V1.Response.error(
        conn,
        :too_many_requests,
        "rate_limited",
        "Too many requests. Try again in #{retry_after} seconds."
      )
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(
        :too_many_requests,
        "Too many requests. Try again in #{retry_after} seconds."
      )
    end
  end

  defp json_request?(conn) do
    String.starts_with?(conn.request_path, "/api/") or
      "application/json" in get_req_header(conn, "accept") or
      "application/json" in get_req_header(conn, "content-type")
  end
end
