defmodule VeejrWeb.CrapsComponents do
  @moduledoc """
  The craps table as it is drawn, shared by the member page and the guest one.

  Both show the same felt, the same roster and the same chip tray, and differ
  only in how you take a seat and in what sits underneath. One template means
  a rule added to the board cannot reach one page and miss the other.

  Everything here is a function of the state it is handed. The two LiveViews
  own identity, the events, and the holding back of outcomes.
  """

  use VeejrWeb, :html

  alias Veejr.AddOns.Craps.{Bets, Rng}

  @chip_denominations [5, 10, 25, 100]

  # Pip positions in each face's 3x3 grid, so the faces read like real dice
  # rather than a count of dots.
  @pips %{
    1 => [5],
    2 => [1, 9],
    3 => [1, 5, 9],
    4 => [1, 3, 7, 9],
    5 => [1, 3, 5, 7, 9],
    6 => [1, 3, 4, 6, 7, 9]
  }

  # The order the stylesheet positions as front, bottom, right, left, top,
  # and back. Opposite faces sum to seven, as they must.
  @face_order [1, 2, 3, 4, 5, 6]

  @doc """
  How long to wait for a browser to say the dice have stopped before showing
  the outcome regardless. The throw itself runs about four seconds.
  """
  def reveal_grace_ms, do: 7_000

  @doc "Whether this state carries a roll the page has not yet shown."
  def new_roll?(_shown, %{last_roll: nil}), do: false
  def new_roll?(%{last_roll: nil}, _table), do: true
  def new_roll?(shown, table), do: table.last_roll.id != shown.last_roll.id

  attr :shown, :map, required: true, doc: "the state a player is allowed to see"
  attr :table, :map, required: true, doc: "the truth, which only feeds the dice their faces"
  attr :rolling, :any, default: nil
  attr :stake, :integer, required: true
  attr :dice_mode, :string, required: true
  attr :player_id, :any, required: true
  attr :me, :map, default: nil
  attr :title, :string, default: "Craps"

  attr :summary, :string,
    default: "A shared table with 3D dice, play-money chips, and invited friends."

  attr :trust_note, :string, required: true

  slot :seat_control, required: true
  slot :inner_block

  def table_view(assigns) do
    assigns =
      assigns
      |> assign(:my_bets, my_bets(assigns.shown, assigns.player_id))
      |> assign(:shooter?, assigns.shown.shooter_id == assigns.player_id)
      |> assign(:denominations, @chip_denominations)

    ~H"""
    <div class="space-y-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold">{@title}</h1>
          <p class="opacity-70">{@summary}</p>
        </div>
        <div :if={@me} class="text-right">
          <p class="text-xs tracking-wider uppercase opacity-55">Your chips</p>
          <p class="text-2xl font-semibold tabular-nums">{@me.chips}</p>
        </div>
      </div>

      <details class="rounded-2xl border border-warning/40 bg-warning/10 p-4">
        <summary class="flex cursor-pointer items-center gap-2 font-medium select-none">
          <.icon name="hero-exclamation-triangle" class="size-5" /> This table is refereed
        </summary>
        <p class="mt-2 text-sm opacity-80">{@trust_note}</p>
        <p class="mt-2 text-sm opacity-80">{dice_description(@dice_mode)}</p>
      </details>

      <%!-- The felt and the heads-up display that goes over it in full
            screen. They are wrapped because the felt is phx-update="ignore" —
            the scene owns that DOM — so anything that has to keep updating
            must be a sibling rather than a child of it. --%>
      <div id="craps-stage" class="relative">
        <%!-- Everything the felt needs, three.js included, is fetched on
              arrival here; the CSS dice below stand in when WebGL is out. --%>
        <div
          id="craps-felt"
          phx-hook="CrapsTable"
          phx-update="ignore"
          data-three-src={~p"/vendor/three.min.js"}
          data-table={Jason.encode!(scene_state(@shown, @table, @player_id))}
          class="group aspect-[16/10] w-full overflow-hidden rounded-2xl border border-base-300 bg-base-300 sm:aspect-[2/1]"
        >
        </div>

        <%!-- Hidden until the felt fills the screen: in the page these same
              numbers already sit underneath it. --%>
        <div id="craps-hud" class="craps-hud" aria-hidden="true">
          <div class="craps-hud-bar">
            <div :if={@me} class="craps-hud-chips">
              <span class="craps-hud-label">Chips</span>
              <strong class="tabular-nums">{@me.chips}</strong>
            </div>

            <form :if={@me} phx-change="stake" class="craps-hud-stake">
              <label class="craps-hud-label" for="craps-hud-stake">Chip</label>
              <select id="craps-hud-stake" name="amount" class="select select-sm">
                <option :for={amount <- @denominations} value={amount} selected={@stake == amount}>
                  {amount}
                </option>
              </select>
            </form>

            <div :if={@me && @shooter?} class="craps-hud-roll">
              <button
                id="craps-hud-roll"
                phx-click="roll"
                class="btn btn-primary btn-sm"
                disabled={not has_line_bet?(@my_bets) or @rolling != nil}
              >
                <.icon name="hero-cube" class="size-4" /> Roll
              </button>
            </div>
          </div>

          <div :if={@me} class="craps-hud-bets">
            <span class="craps-hud-label">Your bets</span>
            <p :if={@my_bets == []} class="craps-hud-empty">Nothing down yet.</p>
            <ul>
              <li :for={bet <- @my_bets}>
                <span>
                  {bet_label(bet.type)}
                  <span :if={bet.target} class="opacity-60">
                    &nbsp;on {bet.target}
                  </span>
                </span>
                <strong class="tabular-nums">{bet.amount}</strong>
              </li>
            </ul>
          </div>
        </div>
      </div>
      <div class="-mt-2 flex flex-wrap items-center justify-center gap-3 text-xs opacity-45">
        <span>Drag to look around the table, scroll to zoom.</span>
        <button
          id="craps-fullscreen"
          type="button"
          phx-hook=".Fullscreen"
          phx-update="ignore"
          class="btn btn-ghost btn-xs gap-1"
          aria-pressed="false"
        >
          <.icon name="hero-arrows-pointing-out" class="size-3.5" />
          <span data-role="label">Full screen</span>
        </button>
        <%!-- Sound is this browser's business, not the session's, so the
                toggle never reaches the server. --%>
        <button
          id="craps-sound"
          type="button"
          phx-hook=".Sound"
          phx-update="ignore"
          class="btn btn-ghost btn-xs gap-1"
          aria-pressed="false"
        >
          <.icon name="hero-speaker-x-mark" class="size-3.5" />
          <span data-role="label">Sound off</span>
        </button>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Fullscreen">
        // Takes the felt itself full screen rather than the page, so the
        // canvas fills the display and the scene's ResizeObserver picks the
        // new size up on its own.
        export default {
          mounted() {
            // The stage, not the felt: the heads-up display is a sibling of
            // the canvas, and both have to come along.
            const felt = () => document.getElementById("craps-stage")

            this.toggle = () => {
              if (document.fullscreenElement) {
                document.exitFullscreen()
                return
              }

              const request = felt()?.requestFullscreen?.()
              // An embedded context can report fullscreenEnabled and still
              // refuse the call. A button that silently does nothing is worse
              // than no button, so take it away.
              if (request) request.catch(() => (this.el.hidden = true))
            }

            this.paint = () => {
              const on = document.fullscreenElement === felt()
              const hud = document.getElementById("craps-hud")
              if (hud) hud.setAttribute("aria-hidden", on ? "false" : "true")
              this.el.setAttribute("aria-pressed", on ? "true" : "false")
              this.el.querySelector("[data-role=label]").textContent =
                on ? "Exit full screen" : "Full screen"
              const icon = this.el.querySelector("span[class*='hero-arrows-pointing']")
              if (icon) {
                icon.classList.toggle("hero-arrows-pointing-in", on)
                icon.classList.toggle("hero-arrows-pointing-out", !on)
              }
            }

            this.el.addEventListener("click", this.toggle)
            document.addEventListener("fullscreenchange", this.paint)

            if (!document.fullscreenEnabled) this.el.hidden = true
          },

          destroyed() {
            this.el.removeEventListener("click", this.toggle)
            document.removeEventListener("fullscreenchange", this.paint)
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Sound">
        const KEY = "veejr:craps-sound"

        export default {
          mounted() {
            this.on = window.localStorage.getItem(KEY) === "on"
            this.paint()

            this.toggle = () => {
              this.on = !this.on
              try { window.localStorage.setItem(KEY, this.on ? "on" : "off") } catch (_e) {}
              this.paint()
              window.dispatchEvent(new CustomEvent("veejr:craps-sound", {detail: this.on}))
            }

            this.el.addEventListener("click", this.toggle)
          },

          destroyed() {
            this.el.removeEventListener("click", this.toggle)
          },

          paint() {
            this.el.setAttribute("aria-pressed", this.on ? "true" : "false")
            this.el.querySelector("[data-role=label]").textContent =
              this.on ? "Sound on" : "Sound off"
            const icon = this.el.querySelector("span.hero-speaker-x-mark, span.hero-speaker-wave")
            if (icon) {
              icon.classList.toggle("hero-speaker-wave", this.on)
              icon.classList.toggle("hero-speaker-x-mark", !this.on)
            }
          }
        }
      </script>

      <div class="rounded-2xl border border-base-300 bg-base-100 p-5">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <p class="text-xs tracking-wider uppercase opacity-55">
              {if @shown.phase == :come_out, do: "Come out", else: "Point"}
            </p>
            <p class="text-3xl font-semibold">
              {if @shown.point, do: @shown.point, else: "—"}
            </p>
          </div>

          <div class="text-center">
            <%!-- Shown only when the WebGL table did not come up; the
                    stylesheet hides these once the felt reports ready. --%>
            <div id="craps-dice-fallback">
              <.dice roll={@table.last_roll} />
            </div>
            <p
              :if={@shown.last_roll && is_nil(@rolling)}
              class="mt-2 text-sm font-medium tabular-nums"
            >
              {@shown.last_roll.die1} + {@shown.last_roll.die2} = {@shown.last_roll.total}
            </p>
            <p :if={@shown.last_roll && is_nil(@rolling)} class="text-sm opacity-70">
              {event_label(@shown.last_roll.event)}
            </p>
            <p :if={is_nil(@shown.last_roll) and is_nil(@rolling)} class="mt-2 text-sm opacity-55">
              No roll yet
            </p>
            <p :if={@rolling} id="craps-rolling" class="mt-2 text-sm opacity-55">
              Dice in the air…
            </p>
          </div>

          <div class="flex gap-2">
            {render_slot(@seat_control)}
            <button
              :if={@me && @shooter?}
              id="craps-roll"
              phx-click="roll"
              class="btn btn-primary"
              disabled={not has_line_bet?(@my_bets) or @rolling != nil}
            >
              <.icon name="hero-cube" class="size-5" /> Roll the dice
            </button>
            <button :if={@me} phx-click="leave" class="btn btn-outline btn-sm">Leave</button>
          </div>
        </div>

        <p :if={@me && @shooter? && not has_line_bet?(@my_bets)} class="mt-3 text-sm opacity-70">
          You have the dice. Put a Pass Line or Don't Pass bet down before you roll.
        </p>
      </div>

      <div id="craps-seats" class="rounded-2xl border border-base-300 bg-base-100 p-5">
        <h2 class="font-medium">
          At the table <span class="opacity-55">({length(@shown.seats)}/{@shown.max_players})</span>
        </h2>
        <p :if={@shown.seats == []} class="mt-2 text-sm opacity-60">Nobody is playing yet.</p>
        <ul class="mt-3 space-y-1">
          <li
            :for={player <- @shown.seats}
            class="flex items-center justify-between gap-3 text-sm"
          >
            <span class="flex items-center gap-2">
              <.icon
                :if={player.user_id == @shown.shooter_id}
                name="hero-cube"
                class="size-4 text-primary"
              />
              <span class={if player.user_id == @shown.shooter_id, do: "font-medium"}>
                {player.display_name || "@#{player.username}"}
              </span>
              <span :if={player.user_id == @shown.shooter_id} class="badge badge-primary badge-sm">
                Shooter
              </span>
            </span>
            <span class="tabular-nums opacity-70">{player.chips}</span>
          </li>
        </ul>
      </div>

      <div :if={@me} class="rounded-2xl border border-base-300 bg-base-100 p-5">
        <div class="flex flex-wrap items-center gap-3">
          <h2 class="font-medium">Chip</h2>
          <div class="join">
            <button
              :for={amount <- @denominations}
              phx-click="stake"
              phx-value-amount={amount}
              class={[
                "btn join-item btn-sm",
                if(@stake == amount, do: "btn-primary", else: "btn-outline")
              ]}
            >
              {amount}
            </button>
          </div>
          <p class="text-sm opacity-60">
            Pick a chip, then drop it on the felt. Put a chip on your own line
            bet to lay odds behind it, or on a come-point marker for odds on
            that number.
          </p>
        </div>
      </div>

      <div
        :if={@my_bets != []}
        id="craps-my-bets"
        class="rounded-2xl border border-base-300 bg-base-100 p-5"
      >
        <h2 class="font-medium">Your bets on the felt</h2>
        <ul class="mt-3 grid gap-2 sm:grid-cols-2">
          <li
            :for={bet <- @my_bets}
            class="flex items-center justify-between rounded-lg bg-base-200 px-3 py-2 text-sm"
          >
            <span>
              {bet_label(bet.type)}
              <span :if={bet.target} class="opacity-60">on {bet.target}</span>
            </span>
            <span class="font-medium tabular-nums">{bet.amount}</span>
          </li>
        </ul>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :roll, :map, default: nil

  def dice(assigns) do
    assigns =
      assigns
      |> assign(:die1, (assigns.roll && assigns.roll.die1) || 1)
      |> assign(:die2, (assigns.roll && assigns.roll.die2) || 2)
      |> assign(:roll_id, (assigns.roll && Map.get(assigns.roll, :id, 0)) || 0)

    ~H"""
    <div
      id="craps-dice"
      phx-hook=".Dice"
      data-die1={@die1}
      data-die2={@die2}
      data-roll-id={@roll_id}
    >
      <%!-- The cubes are inert DOM the hook owns: all six faces are always
            rendered and only the transform changes, so LiveView has no reason
            to patch them and would only fight the animation if it did. --%>
      <div id="craps-dice-cubes" class="craps-dice" phx-update="ignore">
        <.die value={@die1} />
        <.die value={@die2} />
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Dice">
      // Rotation that brings a given face to the front, matching the face
      // order the stylesheet lays out.
      const FACING = {1: [0, 0], 2: [90, 0], 3: [0, -90], 4: [0, 90], 5: [-90, 0], 6: [0, 180]}

      export default {
        mounted() {
          this.turns = 0
          this.shown = null
          this.settle(false)
        },

        updated() {
          this.settle(true)
        },

        settle(animate) {
          const rollId = this.el.dataset.rollId
          if (rollId === this.shown) return

          // Only a roll the browser has not seen tumbles; a re-render for
          // somebody else's bet must not re-throw the dice.
          const fresh = animate && this.shown !== null
          this.shown = rollId
          if (fresh) this.turns += 3

          const faces = [this.el.dataset.die1, this.el.dataset.die2].map(Number)

          this.el.querySelectorAll(".craps-die").forEach((die, index) => {
            const [x, y] = FACING[faces[index]] || [0, 0]
            const spin = 360 * (this.turns + (fresh ? index : 0))
            die.style.transform = `rotateX(${x - spin}deg) rotateY(${y + spin}deg)`
          })

          // The server is holding the outcome until the dice stop. Only report
          // when these dice are the ones actually on screen — when the WebGL
          // table is up they are hidden, and it reports for itself several
          // seconds later.
          if (document.documentElement.classList.contains("craps-webgl")) return

          // Only a fresh throw is being waited on; the first render is just
          // the state as it already stands.
          if (!fresh) return

          let reported = false
          const done = () => {
            if (reported) return
            reported = true
            this.pushEvent("dice_settled", {id: Number(rollId)})
          }

          const die = this.el.querySelector(".craps-die")
          if (!die) return done()

          die.addEventListener("transitionend", done, {once: true})
          // A transition that never fires (reduced motion, a hidden tab) must
          // not strand the table waiting on it.
          setTimeout(done, 1600)
        }
      }
    </script>
    """
  end

  attr :value, :integer, required: true

  defp die(assigns) do
    assigns = assign(assigns, :faces, Enum.map(@face_order, &{&1, Map.fetch!(@pips, &1)}))

    ~H"""
    <div class="craps-die" aria-label={"Die showing #{@value}"} role="img">
      <div :for={{_face, pips} <- @faces} class="craps-die-face">
        <span :for={cell <- 1..9} class={["craps-die-pip", cell not in pips && "invisible"]}></span>
      </div>
    </div>
    """
  end

  # What the WebGL table needs. The felt itself decides nothing: it draws what
  # is here and reports which region was clicked.
  # `shown` is what the felt may reveal; `table` supplies only the faces the
  # dice are on their way to. Everything else — the puck, the chips, which
  # bets are still live — stays as it was until the throw has landed.
  def scene_state(shown, table, user_id) do
    mine = my_bets(shown, user_id)

    %{
      phase: shown.phase,
      point: shown.point,
      seated: seat(shown, user_id) != nil,
      last_roll:
        table.last_roll &&
          %{
            id: Map.get(table.last_roll, :id, 0),
            die1: table.last_roll.die1,
            die2: table.last_roll.die2,
            # The croupier's call, which the felt speaks only once the dice
            # are down. It carries nothing the faces above do not already
            # give away — a client that must animate the result cannot be
            # kept from knowing it.
            total: table.last_roll.total,
            event: table.last_roll.event
          },
      # Every player's action, not just yours: a craps table you cannot read
      # is half a game, and the whole point of a shared felt is watching where
      # the money is. Each bet carries the station its owner works, so chips
      # land in front of the player they belong to rather than in one heap.
      bets: positioned_bets(shown, user_id),
      actions: felt_actions(shown, mine)
    }
  end

  @doc """
  Every bet on the felt, tagged with where its owner stands.

  A double-ended craps layout has two identical halves so players at either
  end can reach their own. Seats alternate between them — the first to sit
  takes the left, the next the right, and so on — which keeps a full table
  balanced instead of crowding seven people onto one end. Each player then
  gets their own lane along their half, so no two players' chips land on the
  same square inch.
  """
  def positioned_bets(shown, user_id) do
    stations =
      shown.seats
      |> Enum.with_index()
      |> Map.new(fn {seat, index} ->
        station = %{
          side: if(rem(index, 2) == 0, do: "left", else: "right"),
          slot: div(index, 2)
        }

        {seat.user_id, station}
      end)

    Enum.map(shown.bets, fn bet ->
      station = Map.get(stations, bet.player_id, %{side: "left", slot: 0})

      %{
        type: bet.type,
        target: bet.target,
        amount: bet.amount,
        mine: bet.player_id == user_id,
        side: station.side,
        slot: station.slot
      }
    end)
  end

  # What a chip dropped on each region would do right now, so the felt can
  # label it on hover and dim what the rules do not allow. Keyed by bet type
  # because that is what a region carries.
  defp felt_actions(table, mine) do
    Map.new(Bets.types(), fn type ->
      {Atom.to_string(type), action_for(type, table, mine)}
    end)
  end

  # Dropping a chip on your own line bet lays odds behind it, the way it works
  # standing at a table — there is no separate odds box painted on a felt.
  defp action_for(type, table, mine) when type in [:pass_line, :dont_pass] do
    odds = if type == :pass_line, do: :pass_odds, else: :dont_pass_odds

    cond do
      table.phase == :point and holds?(mine, type) ->
        %{
          bet: Atom.to_string(odds),
          label: "#{bet_label(odds)} behind your #{bet_label(type)}",
          enabled: true
        }

      Bets.placeable?(type, table.phase) and not holds?(mine, type) ->
        %{bet: Atom.to_string(type), label: bet_label(type), enabled: true}

      holds?(mine, type) ->
        %{bet: nil, label: "#{bet_label(type)} — already down", enabled: false}

      true ->
        %{bet: nil, label: "#{bet_label(type)} — not this roll", enabled: false}
    end
  end

  defp action_for(type, table, _mine) do
    if Bets.placeable?(type, table.phase) do
      %{bet: Atom.to_string(type), label: bet_label(type), enabled: true}
    else
      %{bet: nil, label: "#{bet_label(type)} — not this roll", enabled: false}
    end
  end

  defp holds?(bets, type), do: Enum.any?(bets, &(&1.type == type))

  def seat(table, user_id), do: Enum.find(table.seats, &(&1.user_id == user_id))

  def my_bets(table, user_id), do: Enum.filter(table.bets, &(&1.player_id == user_id))

  defp has_line_bet?(bets), do: Enum.any?(bets, &(&1.type in [:pass_line, :dont_pass]))

  defp bet_label(:pass_line), do: "Pass line"
  defp bet_label(:dont_pass), do: "Don't pass"
  defp bet_label(:pass_odds), do: "Pass odds"
  defp bet_label(:dont_pass_odds), do: "Don't pass odds"
  defp bet_label(:come), do: "Come"
  defp bet_label(:dont_come), do: "Don't come"
  defp bet_label(:come_odds), do: "Come odds"
  defp bet_label(:dont_come_odds), do: "Don't come odds"
  defp bet_label(:field), do: "Field"
  defp bet_label(:any_seven), do: "Any seven"
  defp bet_label(:any_craps), do: "Any craps"
  defp bet_label(:yo), do: "Yo (11)"
  defp bet_label(:aces), do: "Aces (2)"
  defp bet_label(:ace_deuce), do: "Ace-deuce (3)"
  defp bet_label(:boxcars), do: "Boxcars (12)"
  defp bet_label(:horn), do: "Horn"
  defp bet_label(:big_6), do: "Big 6"
  defp bet_label(:big_8), do: "Big 8"

  defp bet_label(type) do
    type |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp event_label(:natural), do: "Natural — pass line wins"
  defp event_label(:craps), do: "Craps — pass line loses"
  defp event_label(:point_set), do: "Point established"
  defp event_label(:point_made), do: "Point made — pass line wins"
  defp event_label(:seven_out), do: "Seven out — the dice move on"
  defp event_label(:roll), do: "No change"

  def bet_error(:invalid_phase), do: "That bet cannot be placed right now."
  def bet_error(:duplicate_bet), do: "You already have that bet down."
  def bet_error(:no_base_bet), do: "You need the underlying bet before you can take odds."
  def bet_error(:missing_target), do: "Pick the number those odds ride on."
  def bet_error(:insufficient_chips), do: "You do not have enough chips for that."
  def bet_error(:not_at_table), do: "Take a seat first."
  def bet_error(:invalid_amount), do: "That is not a valid stake."
  def bet_error(:invalid_bet_type), do: "The table does not take that bet."

  def roll_error(:not_shooter), do: "Only the shooter can throw the dice."
  def roll_error(:no_shooter), do: "Nobody has the dice."
  def roll_error(:shooter_needs_line_bet), do: "Put a line bet down before you roll."

  defp dice_description("fair"),
    do: "Fair — every combination is equally likely, 1 in 36. Nobody has an edge on the roll."

  defp dice_description("house"),
    do:
      "House edge — a seven is #{Rng.seven_bias()} times likelier than it should be. " <>
        "Disclosed here because dice weighted in secret by one of the players " <>
        "would just be cheating."
end
