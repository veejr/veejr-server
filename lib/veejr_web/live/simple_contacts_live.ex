defmodule VeejrWeb.SimpleContactsLive do
  @moduledoc """
  Contacts with everything but the people taken out: a photo and a name.

  The full page at `/contacts` still owns friend requests, groups, notes,
  delivery settings, and appearances. This one answers a single question —
  who do I want to talk to — so every tile is a link straight into the
  matching simple thread.
  """
  use VeejrWeb, :live_view

  alias Veejr.{Messaging, Presence, Social}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-3xl space-y-8"
    >
      <header class="flex items-baseline justify-between gap-4">
        <h1 class="text-lg font-semibold leading-8">Contacts</h1>
        <.link
          id="simple-contacts-full-view"
          navigate={~p"/contacts"}
          class="text-sm font-medium text-primary hover:underline"
        >
          Full contacts
        </.link>
      </header>

      <p
        :if={@friends == []}
        id="simple-contacts-empty"
        class="rounded-2xl border border-dashed border-base-300 p-12 text-center text-sm opacity-70"
      >
        No contacts yet. <.link navigate={~p"/contacts"} class="link link-primary">Add someone</.link>
        to get started.
      </p>

      <ul
        :if={@friends != []}
        id="simple-contacts-list"
        class="grid grid-cols-2 gap-x-4 gap-y-8 sm:grid-cols-3 md:grid-cols-4"
      >
        <li :for={friend <- @friends}>
          <.link
            id={"simple-contact-#{friend.id}"}
            navigate={~p"/messages/simple?friend=#{friend.id}"}
            class="flex flex-col items-center gap-3 rounded-2xl p-3 text-center transition hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <span class="relative inline-flex">
              <.user_avatar
                user={friend}
                class="size-20 text-xl sm:size-24 sm:text-2xl"
                ring={false}
              />
              <.presence_dot
                id={"simple-contact-presence-#{friend.id}"}
                state={Map.get(@presence, friend.id, :unknown)}
              />
            </span>
            <span class="w-full truncate text-sm font-medium">{contact_name(friend)}</span>
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Contacts") |> refresh()}
  end

  # Only the dot changes, so patch the map rather than re-reading every friend.
  @impl true
  def handle_info({:veejr_presence, user_id, state}, socket) do
    {:noreply, assign(socket, :presence, Map.put(socket.assigns.presence, user_id, state))}
  end

  # A new encrypted item only matters here for the count on the Contacts link.
  def handle_info({:veejr_notification, _notification}, socket), do: {:noreply, refresh(socket)}

  # Everything else on the user's topic belongs to other views; without this
  # clause a new broadcast would take the page down.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket) do
    user = socket.assigns.current_scope.user
    friends = Social.list_friends(user)

    assign(socket,
      friends: friends,
      presence: Presence.states(friends),
      pending_count: length(Messaging.list_pending_notifications(user))
    )
  end

  defp contact_name(friend), do: friend.display_name || Social.Address.handle(friend)
end
