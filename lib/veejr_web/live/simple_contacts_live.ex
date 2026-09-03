defmodule VeejrWeb.SimpleContactsLive do
  @moduledoc """
  Contacts with everything but the people taken out: a photo and a name.

  The full page at `/contacts` still owns friend requests, groups, notes,
  delivery settings, and appearances. This one answers a single question —
  who do I want to talk to — so every tile is a link straight into the
  matching simple thread.

  Three buttons ring each photo, for the three things you do with a person
  rather than with a page: call them, play something with them, and tell them
  where you are. Each asks a single question and then gets out of the way —
  call now or schedule it, which game, is this about where you are standing.

  A location note is real end-to-end encrypted mail. The `Composer` hook seals
  it in the browser exactly as it does on `/map`, the coordinates come from
  the browser and never travel as a LiveView event, and the recipient is
  already filled in because you started from their face.
  """
  use VeejrWeb, :live_view

  import VeejrWeb.MessagingComponents, only: [composer: 1]

  alias Veejr.Accounts.User
  alias Veejr.AddOns
  alias Veejr.AddOns.Craps
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
                class="size-24 text-2xl sm:size-28 sm:text-3xl"
                ring={false}
              />
              <span class="absolute -right-2 -bottom-2 flex size-7 items-center justify-center rounded-full bg-primary text-primary-content ring-2 ring-base-100">
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
                class="size-24 text-2xl sm:size-28 sm:text-3xl"
                ring={false}
              />
              <.presence_dot
                id={"simple-contact-presence-#{friend.id}"}
                state={Map.get(@presence, friend.id, :unknown)}
                position="right-2 bottom-2 sm:right-2.5 sm:bottom-2.5"
              />
              <span class="sr-only">{contact_name(friend)}</span>
            </.link>
            <%!--
            The buttons sit at the corners of the photo's box, which is outside
            the circle: at -2.5 each one clips the rim rather than landing on
            it, so together they cover a few percent of the face instead of the
            quarter they took when centred on the edge. They stay full size —
            these are the touch targets — and the ring is only what it takes to
            separate a button from the photo behind it.
            --%>
            <button
              id={"simple-contact-call-#{friend.id}"}
              type="button"
              phx-click="open_call_options"
              phx-value-id={friend.id}
              aria-label={"Call #{contact_name(friend)}"}
              aria-haspopup="dialog"
              aria-controls="simple-call-dialog"
              class="absolute -bottom-2.5 -left-2.5 flex size-8 items-center justify-center rounded-full bg-primary text-primary-content shadow-lg ring-2 ring-base-100 transition hover:scale-110 hover:bg-primary/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary sm:size-9"
            >
              <.icon name="hero-phone" class="size-4" />
            </button>
            <button
              :if={@games != []}
              id={"simple-contact-game-#{friend.id}"}
              type="button"
              phx-click="open_game_options"
              phx-value-id={friend.id}
              aria-label={"Play a game with #{contact_name(friend)}"}
              aria-haspopup="dialog"
              aria-controls="simple-game-dialog"
              class="absolute -top-2.5 -left-2.5 flex size-8 items-center justify-center rounded-full bg-info text-info-content shadow-lg ring-2 ring-base-100 transition hover:scale-110 hover:bg-info/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-info sm:size-9"
            >
              <.icon name="hero-puzzle-piece" class="size-4" />
            </button>
            <button
              id={"simple-contact-location-#{friend.id}"}
              type="button"
              phx-click="open_location_note"
              phx-value-id={friend.id}
              aria-label={"Send #{contact_name(friend)} a location note"}
              aria-haspopup="dialog"
              aria-controls="simple-location-dialog"
              class="absolute -top-2.5 -right-2.5 flex size-8 items-center justify-center rounded-full bg-accent text-accent-content shadow-lg ring-2 ring-base-100 transition hover:scale-110 hover:bg-accent/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent sm:size-9"
            >
              <.icon name="hero-map-pin" class="size-4" />
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

      <.contact_dialog
        :if={@call_contact}
        id="simple-call-dialog"
        contact={@call_contact}
        state={Map.get(@presence, @call_contact.id, :unknown)}
        title={"Call #{contact_name(@call_contact)}?"}
        subtitle="Start a private call now, or choose a time that works for both of you."
        focus="#simple-call-now"
        close_label="Close call options"
      >
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
          phx-click="close_dialog"
          class="btn btn-ghost btn-sm mt-1 rounded-xl"
        >
          Not now
        </button>
      </.contact_dialog>

      <.contact_dialog
        :if={@game_contact}
        id="simple-game-dialog"
        contact={@game_contact}
        state={Map.get(@presence, @game_contact.id, :unknown)}
        title={"Play with #{contact_name(@game_contact)}?"}
        subtitle="Pick a game. They get a nudge on whatever page they have open, so it helps if they are online."
        focus={"#simple-game-#{hd(@games).id}"}
        close_label="Close game options"
      >
        <button
          :for={game <- @games}
          id={"simple-game-#{game.id}"}
          type="button"
          phx-click="start_game"
          phx-value-id={@game_contact.id}
          phx-value-game={game.id}
          phx-disable-with="Opening…"
          class="btn btn-primary h-auto justify-start rounded-2xl px-4 py-3 text-left"
        >
          <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary-content/15">
            <.icon name={game.icon} class="size-4" />
          </span>
          <span class="min-w-0">
            <span class="block font-semibold">{game.name}</span>
            <span class="block text-xs font-normal whitespace-normal opacity-75">
              {game.summary}
            </span>
          </span>
        </button>
        <button
          id="simple-game-cancel"
          type="button"
          phx-click="close_dialog"
          class="btn btn-ghost btn-sm mt-1 rounded-xl"
        >
          Not now
        </button>
      </.contact_dialog>

      <.contact_dialog
        :if={@location_contact}
        id="simple-location-dialog"
        contact={@location_contact}
        state={Map.get(@presence, @location_contact.id, :unknown)}
        title={"Send #{contact_name(@location_contact)} a place?"}
        subtitle={location_subtitle(@location_here, @location_contact)}
        focus={location_focus(@location_here)}
        close_label="Close location options"
        dismiss_on_click_away={!@location_here}
      >
        <button
          :if={!@location_here}
          id="simple-location-here"
          type="button"
          phx-click="location_here"
          class="btn btn-primary h-auto justify-start rounded-2xl px-4 py-3 text-left"
        >
          <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary-content/15">
            <.icon name="hero-map-pin" class="size-4" />
          </span>
          <span>
            <span class="block font-semibold">Yes — where I am now</span>
            <span class="block text-xs font-normal opacity-75">Uses this device's location</span>
          </span>
        </button>
        <.link
          :if={!@location_here}
          id="simple-location-elsewhere"
          navigate={~p"/map?friend=#{@location_contact.id}"}
          class="btn btn-outline h-auto justify-start rounded-2xl px-4 py-3 text-left"
        >
          <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-base-200 text-primary">
            <.icon name="hero-map" class="size-4" />
          </span>
          <span>
            <span class="block font-semibold">No — somewhere else</span>
            <span class="block text-xs font-normal opacity-65">Pick the spot on the map</span>
          </span>
        </.link>

        <div
          :if={@location_here}
          id="simple-location-note"
          phx-hook="CurrentLocation"
          data-composer-id="simple-location-composer"
          class="space-y-3"
        >
          <div class="flex items-center gap-2 rounded-2xl bg-base-200 px-3 py-2">
            <p data-role="location-status" class="min-w-0 flex-1 text-xs leading-5 opacity-70">
              Finding you…
            </p>
            <button
              type="button"
              data-role="locate"
              class="btn btn-ghost btn-xs shrink-0 rounded-full"
            >
              Retry
            </button>
          </div>
          <.composer
            id="simple-location-composer"
            user={@current_scope.user}
            friends={@friends}
            groups={[]}
            kind="location"
            show_recipients={false}
            selected_friend_ids={[@location_contact.id]}
            show_files={false}
            show_options={false}
            text_placeholder="Add a note, e.g. “here until six”"
            submit_label="Send my location"
          />
        </div>
        <button
          id="simple-location-cancel"
          type="button"
          phx-click="close_dialog"
          class="btn btn-ghost btn-sm mt-1 rounded-xl"
        >
          Not now
        </button>
      </.contact_dialog>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :contact, User, required: true
  attr :state, :atom, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :focus, :string, required: true
  attr :close_label, :string, required: true

  attr :dismiss_on_click_away, :boolean,
    default: true,
    doc: "off for the composer, whose emoji menu is reparented onto the body while open"

  slot :inner_block, required: true

  # One sheet, one face, one question. The three dialogs on this page differ
  # only in what they ask, so the chrome is written once rather than three
  # times.
  defp contact_dialog(assigns) do
    ~H"""
    <div
      id={@id}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-mounted={JS.focus(to: @focus)}
      phx-window-keydown="close_dialog"
      phx-key="Escape"
      class="fixed inset-0 z-50 flex items-end justify-center bg-base-content/40 p-4 backdrop-blur-sm sm:items-center"
    >
      <section
        phx-click-away={@dismiss_on_click_away && "close_dialog"}
        class="relative max-h-full w-full max-w-sm overflow-y-auto rounded-3xl border border-base-300 bg-base-100 shadow-2xl"
      >
        <button
          id={"#{@id}-close"}
          type="button"
          phx-click="close_dialog"
          aria-label={@close_label}
          class="absolute top-3 right-3 z-10 flex size-9 items-center justify-center rounded-full bg-base-100/75 transition hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <div class="bg-gradient-to-br from-primary/15 via-base-100 to-secondary/10 px-6 pt-6 pb-5 text-center">
          <span class="relative inline-flex">
            <.user_avatar user={@contact} class="size-16 text-lg" ring={false} />
            <.presence_dot id={"#{@id}-presence"} state={@state} />
          </span>
          <h2 id={"#{@id}-title"} class="mt-3 text-xl font-semibold tracking-tight">
            {@title}
          </h2>
          <p class="mt-1 text-sm leading-relaxed opacity-65">{@subtitle}</p>
        </div>
        <div class="grid gap-2 p-4">
          {render_slot(@inner_block)}
        </div>
      </section>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Contacts")
     |> assign(:games, AddOns.enabled())
     |> close_dialogs()
     |> refresh()}
  end

  @impl true
  def handle_event("open_call_options", %{"id" => id}, socket) do
    {:noreply, assign(socket, :call_contact, find_friend(socket.assigns.friends, id))}
  end

  # No games offered means no button, and no dialog either — the sheet names
  # the first game as the thing to focus, so an empty list has nothing to open.
  def handle_event("open_game_options", %{"id" => id}, socket) do
    contact =
      if socket.assigns.games == [], do: nil, else: find_friend(socket.assigns.friends, id)

    {:noreply, assign(socket, :game_contact, contact)}
  end

  def handle_event("open_location_note", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:location_contact, find_friend(socket.assigns.friends, id))
     |> assign(:location_here, false)}
  end

  # Saying "yes, where I am now" is what puts the form on screen, so the
  # browser is only asked for a fix once somebody has said they want to share
  # one.
  def handle_event("location_here", _params, socket) do
    {:noreply, assign(socket, :location_here, true)}
  end

  def handle_event("close_dialog", _params, socket), do: {:noreply, close_dialogs(socket)}

  def handle_event("start_call", %{"id" => id}, socket) do
    case find_friend(socket.assigns.friends, id) do
      nil ->
        {:noreply, socket |> close_dialogs() |> put_flash(:error, "Could not start the call.")}

      friend ->
        case Calls.start_call(socket.assigns.current_scope.user, friend.id) do
          {:ok, call} ->
            call_path = ~p"/call/#{call.public_id}?#{[return_to: ~p"/contacts/simple"]}"
            {:noreply, push_navigate(socket, to: call_path)}

          {:error, :callee_unreachable} ->
            {:noreply,
             socket
             |> close_dialogs()
             |> put_flash(:error, "Their instance is unreachable right now — try again later.")}

          {:error, _reason} ->
            {:noreply,
             socket |> close_dialogs() |> put_flash(:error, "Could not start the call.")}
        end
    end
  end

  def handle_event("start_game", %{"id" => id, "game" => game}, socket) do
    friend = find_friend(socket.assigns.friends, id)
    add_on = Enum.find(socket.assigns.games, &(to_string(&1.id) == game))

    if friend && add_on do
      nudge(add_on, socket.assigns.current_scope.user, friend)
      {:noreply, push_navigate(socket, to: add_on.path)}
    else
      {:noreply, socket |> close_dialogs() |> put_flash(:error, "Could not open that game.")}
    end
  end

  # The composer asks who it may seal for; the answer is public keys only.
  def handle_event("resolve_recipients", params, socket) do
    {:reply, VeejrWeb.RecipientResolver.resolve(socket.assigns.current_scope.user, params),
     socket}
  end

  # Only `location` is accepted. This page has one form and it shares a place;
  # any other kind arriving on this socket is not something the page offered.
  def handle_event(
        "send_batch",
        %{"kind" => "location", "envelopes" => envelopes} = params,
        socket
      ) do
    opts = Map.take(params, ["client_batch_id"])

    case Messaging.send_batch(socket.assigns.current_scope.user, "location", envelopes, opts) do
      {:ok, _batch_id, _queued} ->
        {:reply, %{ok: true},
         socket |> close_dialogs() |> put_flash(:info, "Sent — it will show on their map.")}

      {:error, _reason} ->
        {:reply, %{error: "Sending failed — are they still your friend?"}, socket}
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

  defp close_dialogs(socket) do
    assign(socket,
      call_contact: nil,
      game_contact: nil,
      location_contact: nil,
      location_here: false
    )
  end

  defp location_subtitle(false, _contact), do: "Is this note about where you are right now?"

  defp location_subtitle(true, contact),
    do: "Only #{contact_name(contact)} gets this, and only they can read it."

  defp location_focus(true), do: "#simple-location-note [data-role=text]"
  defp location_focus(false), do: "#simple-location-here"

  # Craps is the only add-on with a table to be asked to; a second one adds
  # its own clause here rather than a registry built against a single case.
  defp nudge(%{id: :craps}, host, friend), do: Craps.invite(host, friend)
  defp nudge(_add_on, _host, _friend), do: :ok

  defp find_friend(friends, id), do: Enum.find(friends, &(to_string(&1.id) == id))

  defp contact_name(friend), do: friend.display_name || Social.Address.handle(friend)
end
