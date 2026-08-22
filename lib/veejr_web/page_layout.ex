defmodule VeejrWeb.PageLayout do
  @moduledoc """
  Which Contacts and Messages an account is shown, and where each choice goes.

  The appearance themes on the full pages are CSS over identical markup, so a
  JS hook can apply them from browser storage. The plain pages are different
  markup, chosen before anything renders, so this preference lives on the
  account and is read at mount — `/contacts` and `/messages` redirect rather
  than painting the full page and bouncing.

  A deep link still wins over the preference. `/messages?self_notes=true` or
  a group thread asks for something the plain page cannot show, so those stay
  on the full page whatever the account prefers.
  """
  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]
  import Phoenix.Component, only: [assign: 3]

  use Phoenix.VerifiedRoutes,
    endpoint: VeejrWeb.Endpoint,
    router: VeejrWeb.Router,
    statics: VeejrWeb.static_paths()

  alias Veejr.Accounts
  alias Veejr.Accounts.Scope

  @layouts ~w(full simple)

  @doc "The layouts a page may be asked to switch to."
  def layouts, do: @layouts

  @doc "The account's chosen layout, defaulting to the simple pages."
  def current(%{assigns: %{current_scope: %{user: %{page_layout: layout}}}})
      when layout in @layouts,
      do: layout

  def current(_socket), do: "simple"

  @doc "True when the account asked for the plain pages."
  def simple?(socket), do: current(socket) == "simple"

  @doc """
  Saves `chosen` and moves to the page that shows it.

  `showing` is the layout the calling page renders, so choosing what is
  already on screen saves the preference without a pointless navigation.
  """
  def choose(socket, surface, showing, chosen) when chosen in @layouts do
    case Accounts.set_page_layout(socket.assigns.current_scope.user, chosen) do
      {:ok, user} ->
        # Assigns carry across navigation inside a live_session, so the scope
        # has to be refreshed here; otherwise the next Contacts or Messages
        # mount would read the layout this just replaced.
        socket = assign(socket, :current_scope, Scope.for_user(user))

        if chosen == showing do
          socket
        else
          push_navigate(socket, to: route(surface, chosen))
        end

      {:error, _changeset} ->
        put_flash(socket, :error, "Could not save that layout.")
    end
  end

  def choose(socket, _surface, _showing, _chosen) do
    put_flash(socket, :error, "That is not a layout.")
  end

  @doc "Where a surface lives in a given layout."
  def route(:contacts, "simple"), do: ~p"/contacts/simple"
  def route(:contacts, _full), do: ~p"/contacts"
  def route(:messages, "simple"), do: ~p"/messages/simple"
  def route(:messages, _full), do: ~p"/messages"

  @doc """
  Where a request for the full Messages page should go instead, if anywhere.

  Only the parameters the plain page understands travel with it; anything
  else names a capability that page does not have, and asking for it is
  reason enough to stay on the full one.
  """
  def messages_redirect(params) when is_map(params) do
    case Map.drop(params, ["conversation", "friend_id"]) do
      empty when empty == %{} -> simple_messages_path(params)
      _other -> nil
    end
  end

  defp simple_messages_path(%{"conversation" => key}) when is_binary(key),
    do: ~p"/messages/simple?conversation=#{key}"

  defp simple_messages_path(%{"friend_id" => id}), do: ~p"/messages/simple?friend=#{id}"
  defp simple_messages_path(_params), do: ~p"/messages/simple"
end
