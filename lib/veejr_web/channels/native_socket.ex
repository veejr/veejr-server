defmodule VeejrWeb.NativeSocket do
  @moduledoc """
  Realtime socket for native clients (the calls extension of client
  protocol v1).

  Browsers ride the LiveView socket and its session cookie; native apps hold
  revocable device-session bearer tokens instead, so they connect here with
  the same access token they send to `/api/v1`. An expired or revoked token
  is refused at connect time — the client refreshes over HTTP and reconnects.
  """

  use Phoenix.Socket

  alias Veejr.Accounts

  channel "calls:v1", VeejrWeb.NativeCallChannel

  @impl true
  def connect(%{"access_token" => token}, socket, _connect_info) when is_binary(token) do
    case Accounts.get_user_and_api_session_by_access_token(token) do
      {user, session} ->
        {:ok, assign(socket, user: user, api_device_session_id: session.id)}

      nil ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # One socket per device session, so a broadcast of "disconnect" to this id
  # can drop exactly that device.
  @impl true
  def id(socket), do: "native_device_session:#{socket.assigns.api_device_session_id}"
end
