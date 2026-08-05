defmodule VeejrWeb.CrapsGuestLive do
  @moduledoc """
  A seat at the craps table for someone without an account.

  The emailed capability is the whole of the authorization: no user is
  created, nothing is stored about the guest beyond the name they pick, and
  their chips live only in the table process.

  When they are done there is an offer to join veejr properly, which mints a
  real membership invitation from their host. `joined_at` on the capability
  is what keeps that to one per guest.
  """

  use VeejrWeb, :live_view

  alias Veejr.Accounts
  alias Veejr.AddOns
  alias Veejr.AddOns.Craps
  alias Veejr.AddOns.Craps.Table
  alias VeejrWeb.CrapsComponents

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    guest = AddOns.enabled?(:craps) && Craps.guest_by_token(token)

    if guest do
      if connected?(socket), do: Table.subscribe()

      table = Table.state()

      {:ok,
       socket
       |> assign(:page_title, "Craps")
       |> assign(:guest, guest)
       |> assign(:player_id, Craps.guest_player_id(guest))
       |> assign(:dice_mode, AddOns.craps_dice_mode())
       |> assign(:name_form, to_form(%{"display_name" => guest.display_name || ""}, as: :guest))
       |> assign(:stake, 10)
       |> assign(:rolling, nil)
       |> assign(:table, table)
       |> assign(:shown, table)}
    else
      {:ok, assign(socket, guest: nil, page_title: "Craps")}
    end
  end

  @impl true
  def handle_info({:craps_table, table}, socket), do: {:noreply, absorb(socket, table)}

  def handle_info({:reveal, roll_id}, socket) do
    if socket.assigns.rolling == roll_id, do: {:noreply, reveal(socket)}, else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("dice_settled", %{"id" => roll_id}, socket) do
    if socket.assigns.rolling == roll_id, do: {:noreply, reveal(socket)}, else: {:noreply, socket}
  end

  def handle_event("sit", %{"guest" => %{"display_name" => name}}, socket) do
    case Craps.name_guest(socket.assigns.guest, name) do
      {:ok, guest} ->
        case Table.sit_guest(socket.assigns.player_id, guest.display_name) do
          {:ok, table} -> {:noreply, socket |> assign(:guest, guest) |> absorb(table)}
          {:error, :table_full} -> {:noreply, put_flash(socket, :error, "The table is full.")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, name_form: to_form(changeset, as: :guest))}
    end
  end

  def handle_event("leave", _params, socket) do
    {:ok, table} = Table.leave(socket.assigns.player_id)
    {:noreply, absorb(socket, table)}
  end

  def handle_event("stake", %{"amount" => amount}, socket) do
    {:noreply, assign(socket, :stake, String.to_integer(amount))}
  end

  def handle_event("felt_bet", %{"bet" => bet}, socket), do: place(socket, bet, nil)

  def handle_event("felt_odds", %{"target" => target}, socket),
    do: place(socket, "come_odds", target)

  def handle_event("roll", _params, socket) do
    case Table.roll(socket.assigns.player_id) do
      {:ok, _roll} ->
        {:noreply, absorb(socket, Table.state())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, CrapsComponents.roll_error(reason))}
    end
  end

  # The offer only makes sense once, and only while invitations are open.
  def handle_event("join_veejr", _params, socket) do
    guest = socket.assigns.guest

    with {:ok, _invitation, token} <- Accounts.create_invitation(guest.host),
         {:ok, guest} <- Craps.mark_guest_joined(guest) do
      {:noreply,
       socket
       |> assign(:guest, guest)
       |> push_navigate(to: ~p"/users/register?#{%{invite: token, email: guest.invited_email}}")}
    else
      {:error, {:already_joined, _guest}} ->
        {:noreply, put_flash(socket, :error, "Your invitation has already been created.")}

      {:error, :invitations_closed} ->
        {:noreply, put_flash(socket, :error, "Membership invitations are currently closed.")}
    end
  end

  defp place(socket, bet, target) do
    bet_type = String.to_existing_atom(bet)
    target = target && String.to_integer(target)

    case Table.place_bet(socket.assigns.player_id, bet_type, socket.assigns.stake, target) do
      {:ok, _bet} -> {:noreply, absorb(socket, Table.state())}
      {:error, reason} -> {:noreply, put_flash(socket, :error, CrapsComponents.bet_error(reason))}
    end
  end

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
    socket |> assign(:shown, socket.assigns.table) |> assign(:rolling, nil)
  end

  @impl true
  def render(%{guest: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-md py-16 text-center">
        <h1 class="text-2xl font-semibold">That invitation has expired</h1>
        <p class="mt-2 opacity-65">
          Craps invitations last a day. Ask whoever sent it for a fresh link.
        </p>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :me, CrapsComponents.seat(assigns.shown, assigns.player_id))

    ~H"""
    <Layouts.app flash={@flash} container_class="mx-auto max-w-3xl space-y-4">
      <CrapsComponents.table_view
        shown={@shown}
        table={@table}
        rolling={@rolling}
        stake={@stake}
        dice_mode={@dice_mode}
        player_id={@player_id}
        me={@me}
        trust_note={AddOns.get(:craps).trust_note}
      >
        <:seat_control>
          <.form
            :if={is_nil(@me)}
            for={@name_form}
            id="craps-guest-sit"
            phx-submit="sit"
            class="flex flex-wrap items-start gap-2"
          >
            <div class="w-44">
              <.input field={@name_form[:display_name]} placeholder="Your name" />
            </div>
            <button type="submit" class="btn btn-primary btn-sm">Take a seat</button>
          </.form>
        </:seat_control>
      </CrapsComponents.table_view>

      <div class="rounded-2xl border border-base-300 bg-base-100 p-5">
        <h2 class="font-medium">Playing as a guest</h2>
        <p class="mt-1 text-sm opacity-65">
          You are here on a private link from {@guest.host.display_name ||
            "@#{@guest.host.username}"}. Nothing about you is stored beyond the
          name you picked, and your chips disappear when the table resets.
        </p>

        <div :if={is_nil(@guest.joined_at)} class="mt-4 rounded-xl bg-primary/5 p-4">
          <h3 class="font-semibold">Stay on afterwards?</h3>
          <p class="mt-1 text-sm opacity-65">
            Joining veejr is optional and can wait until you are done playing.
            If you do, you and {@guest.host.display_name || "@#{@guest.host.username}"} will be connected automatically and your chips will start being kept.
          </p>
          <button id="craps-join-veejr" phx-click="join_veejr" class="btn btn-primary btn-sm mt-3">
            Join veejr
          </button>
        </div>
        <p :if={@guest.joined_at} class="mt-4 text-sm opacity-65">
          Your membership invitation has already been created.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
