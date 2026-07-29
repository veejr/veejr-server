defmodule VeejrWeb.ClientIp do
  @moduledoc """
  Assigns `:client_ip` during mount for rate limiting inside LiveViews.

  `Phoenix.LiveView.get_connect_info/2` is only readable while mounting, so the
  address has to be resolved once and carried in assigns rather than looked up
  when an event arrives. Attaching this as an `on_mount` hook keeps that from
  being an easy thing to forget in a new LiveView.

  On the disconnected render there is no client to bucket and no event can be
  raised yet, so the assign is `"unknown"` — which `Veejr.RateLimiter` treats
  as unidentifiable and lets through.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :client_ip, resolve(socket))}
  end

  defp resolve(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Veejr.RemoteIp.from_socket(socket)
    else
      "unknown"
    end
  end
end
