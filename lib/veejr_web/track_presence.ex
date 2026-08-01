defmodule VeejrWeb.TrackPresence do
  @moduledoc """
  Registers an authenticated page with `Veejr.Presence`.

  Separate from `VeejrWeb.LiveNotify` because the two answer different
  questions. LiveNotify is about encrypted items arriving, and only the app
  pages want it; presence is about whether someone has veejr open at all, and
  reading your own settings counts just as much as reading a thread. Mounting
  this on both authenticated live sessions is what keeps a user from blinking
  offline the moment they open account settings.

  Tracking needs no matching untrack: the LiveView process is monitored, so
  closing the tab, navigating away, or crashing all release the slot.
  """

  import Phoenix.LiveView, only: [connected?: 1]

  alias Veejr.Presence

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Presence.track(socket.assigns.current_scope.user)

    {:cont, socket}
  end
end
