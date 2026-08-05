defmodule VeejrWeb.CrapsLive do
  @moduledoc """
  The craps table.

  Refuses to mount unless the instance offers the add-on, so the page is
  closed rather than merely unlinked when an administrator turns it off.
  """

  use VeejrWeb, :live_view

  alias Veejr.Accounts.UserNotifier
  alias Veejr.AddOns
  alias Veejr.AddOns.Craps
  alias Veejr.AddOns.Craps.Table
  alias Veejr.Social
  alias VeejrWeb.CrapsComponents

  # A throw takes about four seconds to land, and the server resolves the roll
  # the instant it is made. So the page keeps two states: `@table` is the
  # truth and feeds the dice their faces, while `@shown` is what a player sees
  # and is held back until the browser reports the dice at rest.
  #
  # While a throw is in flight *every* update is held, not just the roll —
  # once the server has resolved, every broadcast after it carries the outcome.

  @impl true
  def mount(_params, _session, socket) do
    if AddOns.enabled?(:craps) do
      if connected?(socket), do: Table.subscribe()

      table = Table.state()

      {:ok,
       socket
       |> assign(:add_on, AddOns.get(:craps))
       |> assign(:dice_mode, AddOns.craps_dice_mode())
       |> assign(:stake, 10)
       |> assign(:rolling, nil)
       |> assign(:friends, Social.list_friends(socket.assigns.current_scope.user))
       |> assign(:invited, MapSet.new())
       |> assign(:guests, Craps.list_guests(socket.assigns.current_scope.user))
       |> assign(:guest_form, to_form(Craps.change_guest_invitation(), as: "guest"))
       |> assign(:table, table)
       |> assign(:shown, table)}
    else
      {:ok,
       socket
       |> put_flash(:error, "This instance does not offer craps.")
       |> push_navigate(to: ~p"/contacts")}
    end
  end

  @impl true
  def handle_info({:craps_table, table}, socket), do: {:noreply, absorb(socket, table)}

  # The browser never reported the dice landing — a backgrounded tab, a failed
  # animation. Reveal anyway rather than leaving the table frozen.
  def handle_info({:reveal, roll_id}, socket) do
    if socket.assigns.rolling == roll_id, do: {:noreply, reveal(socket)}, else: {:noreply, socket}
  end

  @impl true
  def handle_event("dice_settled", %{"id" => roll_id}, socket) do
    if socket.assigns.rolling == roll_id, do: {:noreply, reveal(socket)}, else: {:noreply, socket}
  end

  def handle_event("sit", _params, socket) do
    case Table.sit(socket.assigns.current_scope.user) do
      {:ok, table} -> {:noreply, absorb(socket, table)}
      {:error, :table_full} -> {:noreply, put_flash(socket, :error, "The table is full.")}
    end
  end

  def handle_event("leave", _params, socket) do
    {:ok, table} = Table.leave(socket.assigns.current_scope.user.id)

    {:noreply,
     socket
     |> absorb(table)
     |> put_flash(:info, "You left the table. Unresolved bets were refunded.")}
  end

  def handle_event("stake", %{"amount" => amount}, socket) do
    {:noreply, assign(socket, :stake, String.to_integer(amount))}
  end

  def handle_event("validate_guest", %{"guest" => params}, socket) do
    form =
      params
      |> Craps.change_guest_invitation()
      |> Map.put(:action, :validate)
      |> to_form(as: "guest")

    {:noreply, assign(socket, guest_form: form)}
  end

  def handle_event("invite_guest", %{"guest" => params}, socket) do
    host = socket.assigns.current_scope.user

    case Craps.invite_guest(host, params) do
      {:ok, guest, token} ->
        UserNotifier.deliver_craps_guest_invitation(
          host,
          guest.invited_email,
          url(~p"/craps/guest/#{token}")
        )

        {:noreply,
         socket
         |> assign(:guests, Craps.list_guests(host))
         |> assign(:guest_form, to_form(Craps.change_guest_invitation(), as: "guest"))
         |> put_flash(:info, "Emailed a seat to #{guest.invited_email}.")}

      {:error, changeset} ->
        {:noreply, assign(socket, guest_form: to_form(changeset, as: "guest"))}
    end
  end

  def handle_event("invite", %{"id" => id}, socket) do
    friend = Enum.find(socket.assigns.friends, &(to_string(&1.id) == id))

    case friend && Craps.invite(socket.assigns.current_scope.user, friend) do
      :ok ->
        name = friend.display_name || "@#{friend.username}"

        {:noreply,
         socket
         |> update(:invited, &MapSet.put(&1, friend.id))
         |> put_flash(:info, "Asked #{name} to come and play.")}

      _otherwise ->
        {:noreply, put_flash(socket, :error, "Could not send that invitation.")}
    end
  end

  def handle_event("bet", params, socket) do
    bet_type = String.to_existing_atom(params["type"])
    target = params["target"] && String.to_integer(params["target"])

    case Table.place_bet(
           socket.assigns.current_scope.user.id,
           bet_type,
           socket.assigns.stake,
           target
         ) do
      {:ok, _bet} -> {:noreply, absorb(socket, Table.state())}
      {:error, reason} -> {:noreply, put_flash(socket, :error, CrapsComponents.bet_error(reason))}
    end
  end

  # A chip dropped on the felt. The region only reports which bet it is; the
  # rules about odds and phases were decided server-side in felt_actions/2.
  def handle_event("felt_bet", %{"bet" => bet}, socket) do
    handle_event("bet", %{"type" => bet, "target" => nil}, socket)
  end

  def handle_event("felt_odds", %{"target" => target}, socket) do
    handle_event("bet", %{"type" => "come_odds", "target" => target}, socket)
  end

  def handle_event("roll", _params, socket) do
    case Table.roll(socket.assigns.current_scope.user.id) do
      {:ok, _roll} ->
        {:noreply, absorb(socket, Table.state())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, CrapsComponents.roll_error(reason))}
    end
  end

  # Takes in new table state, holding it back from the player if the dice are
  # mid-air or have just been thrown.
  defp absorb(socket, table) do
    socket = assign(socket, :table, table)

    cond do
      socket.assigns.rolling ->
        socket

      CrapsComponents.new_roll?(socket.assigns.shown, table) ->
        roll_id = table.last_roll.id
        Process.send_after(self(), {:reveal, roll_id}, CrapsComponents.reveal_grace_ms())
        assign(socket, :rolling, roll_id)

      true ->
        assign(socket, :shown, table)
    end
  end

  defp reveal(socket) do
    socket
    |> assign(:shown, socket.assigns.table)
    |> assign(:rolling, nil)
  end

  @impl true
  def render(%{add_on: _} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_count={@pending_count}>
      <CrapsComponents.table_view
        shown={@shown}
        table={@table}
        rolling={@rolling}
        stake={@stake}
        dice_mode={@dice_mode}
        player_id={@current_scope.user.id}
        me={CrapsComponents.seat(@shown, @current_scope.user.id)}
        title={@add_on.name}
        summary={@add_on.summary}
        trust_note={@add_on.trust_note}
      >
        <:seat_control>
          <button
            :if={is_nil(CrapsComponents.seat(@shown, @current_scope.user.id))}
            phx-click="sit"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="size-4" /> Take a seat
          </button>
        </:seat_control>

        <div id="craps-invite-friends" class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <h2 class="font-medium">Ask someone to play</h2>
          <p class="mt-1 text-sm opacity-60">
            A friend who has veejr open gets a banner. This is a nudge, not a
            standing invitation — nobody who is away will see it later.
          </p>

          <p :if={@friends == []} class="mt-3 text-sm opacity-60">
            You have not added any friends yet.
          </p>

          <div class="mt-3 flex flex-wrap gap-2">
            <button
              :for={friend <- @friends}
              phx-click="invite"
              phx-value-id={friend.id}
              disabled={MapSet.member?(@invited, friend.id)}
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-hand-raised" class="size-4" />
              {friend.display_name || "@#{friend.username}"}
              <span :if={MapSet.member?(@invited, friend.id)} class="opacity-60">asked</span>
            </button>
          </div>

          <div class="mt-5 border-t border-base-300 pt-4">
            <h3 class="text-sm font-medium">Someone without an account</h3>
            <p class="mt-1 text-sm opacity-60">
              Emails a private link to one seat. They pick a name and play as a
              guest — no account, and their chips last only as long as the table.
            </p>

            <.form
              for={@guest_form}
              id="craps-guest-invite"
              phx-change="validate_guest"
              phx-submit="invite_guest"
              class="mt-3 flex flex-wrap items-start gap-2"
            >
              <div class="min-w-56 flex-1">
                <.input
                  field={@guest_form[:invited_email]}
                  type="email"
                  placeholder="their@email.example"
                />
              </div>
              <button type="submit" class="btn btn-outline btn-sm">
                <.icon name="hero-envelope" class="size-4" /> Email a seat
              </button>
            </.form>

            <ul :if={@guests != []} class="mt-3 space-y-1 text-sm">
              <li :for={guest <- @guests} class="flex items-center justify-between gap-3">
                <span class="opacity-70">{guest.invited_email}</span>
                <span class="opacity-55">
                  {if guest.joined_at, do: "joined veejr", else: "invited"}
                </span>
              </li>
            </ul>
          </div>
        </div>
      </CrapsComponents.table_view>
    </Layouts.app>
    """
  end

  def render(assigns), do: ~H""
end
