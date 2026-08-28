defmodule VeejrWeb.SimpleContactsLive do
  @moduledoc """
  Contacts with everything but the people taken out: a photo and a name.

  The full page at `/contacts` still owns friend requests, groups, notes,
  delivery settings, and appearances. This one answers a single question —
  who do I want to talk to — so every tile is a link straight into the
  matching simple thread.
  """
  use VeejrWeb, :live_view

  alias Veejr.{Calls, Messaging, Presence, Social}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-3xl space-y-8"
    >
      <header class="flex flex-wrap items-center justify-between gap-4">
        <h1 class="text-lg font-semibold leading-8">Contacts</h1>
        <.link navigate={~p"/contacts?manage=true"} class="btn btn-ghost btn-sm">
          <.icon name="hero-user-plus" class="size-4" /> Manage
        </.link>
      </header>

      <p
        :if={@friends == []}
        id="simple-contacts-empty"
        class="rounded-2xl border border-dashed border-base-300 p-12 text-center text-sm opacity-70"
      >
        No contacts yet.
        <.link navigate={~p"/contacts?manage=true"} class="link link-primary">Add someone</.link>
        to get started.
      </p>

      <ul
        id="simple-contacts-list"
        class="grid grid-cols-2 gap-x-4 gap-y-8 sm:grid-cols-3 md:grid-cols-4"
      >
        <li>
          <.link
            id="simple-self-notes"
            navigate={~p"/messages?self_notes=true"}
            class="flex flex-col items-center gap-3 rounded-2xl p-3 text-center transition hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <span class="relative inline-flex">
              <.user_avatar
                user={@current_scope.user}
                class="size-20 text-xl sm:size-24 sm:text-2xl"
                ring={false}
              />
              <span class="absolute -right-1 -bottom-1 flex size-7 items-center justify-center rounded-full bg-primary text-primary-content ring-2 ring-base-100">
                <.icon name="hero-pencil-square" class="size-4" />
              </span>
            </span>
            <span class="w-full truncate text-sm font-medium">Notes to yourself</span>
          </.link>
        </li>
        <li
          :for={friend <- @friends}
          class="flex flex-col items-center gap-3 rounded-2xl p-3 text-center transition hover:bg-base-200"
        >
          <span class="relative inline-flex">
            <.link
              id={"simple-contact-#{friend.id}"}
              navigate={~p"/messages/simple?friend=#{friend.id}"}
              aria-label={"Message #{contact_name(friend)}"}
              class="relative inline-flex rounded-full transition hover:scale-[1.02] focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary"
            >
              <.user_avatar
                user={friend}
                class="size-20 text-xl sm:size-24 sm:text-2xl"
                ring={false}
              />
              <.presence_dot
                id={"simple-contact-presence-#{friend.id}"}
                state={Map.get(@presence, friend.id, :unknown)}
              />
              <span class="sr-only">{contact_name(friend)}</span>
            </.link>
            <button
              id={"simple-contact-call-#{friend.id}"}
              type="button"
              phx-click="open_call_options"
              phx-value-id={friend.id}
              aria-label={"Call #{contact_name(friend)}"}
              aria-haspopup="dialog"
              aria-controls="simple-call-dialog"
              class="absolute -bottom-1 -left-1 flex size-8 items-center justify-center rounded-full bg-primary text-primary-content shadow-lg ring-3 ring-base-100 transition hover:scale-110 hover:bg-primary/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary sm:size-9"
            >
              <.icon name="hero-phone" class="size-4" />
            </button>
          </span>
          <.link
            id={"simple-contact-name-#{friend.id}"}
            navigate={~p"/messages/simple?friend=#{friend.id}"}
            class="w-full truncate rounded-md text-sm font-medium transition hover:text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            {contact_name(friend)}
          </.link>
        </li>
      </ul>

      <div
        :if={@call_contact}
        id="simple-call-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="simple-call-dialog-title"
        phx-mounted={JS.focus(to: "#simple-call-now")}
        phx-window-keydown="close_call_options"
        phx-key="Escape"
        class="fixed inset-0 z-50 flex items-end justify-center bg-base-content/40 p-4 backdrop-blur-sm sm:items-center"
      >
        <section
          phx-click-away="close_call_options"
          class="relative w-full max-w-sm overflow-hidden rounded-3xl border border-base-300 bg-base-100 shadow-2xl"
        >
          <button
            id="simple-call-dialog-close"
            type="button"
            phx-click="close_call_options"
            aria-label="Close call options"
            class="absolute top-3 right-3 z-10 flex size-9 items-center justify-center rounded-full bg-base-100/75 transition hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
          <div class="bg-gradient-to-br from-primary/15 via-base-100 to-secondary/10 px-6 pt-6 pb-5 text-center">
            <span class="relative inline-flex">
              <.user_avatar
                user={@call_contact}
                class="size-16 text-lg"
                ring={false}
              />
              <.presence_dot
                id="simple-call-dialog-presence"
                state={Map.get(@presence, @call_contact.id, :unknown)}
              />
            </span>
            <h2 id="simple-call-dialog-title" class="mt-3 text-xl font-semibold tracking-tight">
              Call {contact_name(@call_contact)}?
            </h2>
            <p class="mt-1 text-sm leading-relaxed opacity-65">
              Start a private call now, or choose a time that works for both of you.
            </p>
          </div>
          <div class="grid gap-2 p-4">
            <button
              id="simple-call-now"
              type="button"
              phx-click="start_call"
              phx-value-id={@call_contact.id}
              phx-disable-with="Starting call…"
              class="btn btn-primary h-auto justify-start rounded-2xl px-4 py-3 text-left"
            >
              <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary-content/15">
                <.icon name="hero-phone" class="size-4" />
              </span>
              <span>
                <span class="block font-semibold">Call now</span>
                <span class="block text-xs font-normal opacity-75">Ring them immediately</span>
              </span>
            </button>
            <.link
              id="simple-schedule-call"
              navigate={~p"/calls?friend_id=#{@call_contact.id}"}
              class="btn btn-outline h-auto justify-start rounded-2xl px-4 py-3 text-left"
            >
              <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-base-200 text-primary">
                <.icon name="hero-calendar-days" class="size-4" />
              </span>
              <span>
                <span class="block font-semibold">Schedule a call</span>
                <span class="block text-xs font-normal opacity-65">Pick a date and time</span>
              </span>
            </.link>
            <button
              id="simple-call-cancel"
              type="button"
              phx-click="close_call_options"
              class="btn btn-ghost btn-sm mt-1 rounded-xl"
            >
              Not now
            </button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Contacts") |> assign(:call_contact, nil) |> refresh()}
  end

  @impl true
  def handle_event("open_call_options", %{"id" => id}, socket) do
    {:noreply, assign(socket, :call_contact, find_friend(socket.assigns.friends, id))}
  end

  def handle_event("close_call_options", _params, socket) do
    {:noreply, assign(socket, :call_contact, nil)}
  end

  def handle_event("start_call", %{"id" => id}, socket) do
    case find_friend(socket.assigns.friends, id) do
      nil ->
        {:noreply,
         socket |> assign(:call_contact, nil) |> put_flash(:error, "Could not start the call.")}

      friend ->
        case Calls.start_call(socket.assigns.current_scope.user, friend.id) do
          {:ok, call} ->
            call_path = ~p"/call/#{call.public_id}?#{[return_to: ~p"/contacts/simple"]}"
            {:noreply, push_navigate(socket, to: call_path)}

          {:error, :callee_unreachable} ->
            {:noreply,
             socket
             |> assign(:call_contact, nil)
             |> put_flash(:error, "Their instance is unreachable right now — try again later.")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:call_contact, nil)
             |> put_flash(:error, "Could not start the call.")}
        end
    end
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

  defp find_friend(friends, id), do: Enum.find(friends, &(to_string(&1.id) == id))

  defp contact_name(friend), do: friend.display_name || Social.Address.handle(friend)
end
