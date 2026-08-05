defmodule Veejr.AddOns.Craps.Table do
  @moduledoc """
  The one craps table an instance runs.

  Holds the roster, the bets on the felt, and whose turn it is to shoot. Like
  `Veejr.WatchParties` there is a single table per instance and it lives only
  in memory: a restart clears the felt. Chip stacks are the exception and are
  written through to the database as they change, because a stack is the
  player's and should survive the server bouncing.

  Seats are keyed by user id rather than by connection, so a reload or a
  dropped socket is not an event the table has to think about — the whole
  reconnect-and-hold dance in the reference implementation exists only because
  its seats were keyed by socket.

  Every mutating call broadcasts the new public state on `subscribe/0`.
  """

  use GenServer

  alias Phoenix.PubSub
  alias Veejr.AddOns
  alias Veejr.AddOns.Craps
  alias Veejr.AddOns.Craps.{Bet, Bets, Resolution, Rng, State}
  alias Veejr.Accounts.User

  @topic "craps_table"
  @max_players 8

  # A shooter who never rolls holds the whole table hostage: nobody else can
  # throw, so every other player's bets sit frozen on the felt. After this
  # long the dice are taken away and the seat is released.
  @idle_timeout_ms 3 * 60 * 1000

  @type error ::
          :table_full
          | :not_at_table
          | :invalid_bet_type
          | :invalid_amount
          | :invalid_phase
          | :duplicate_bet
          | :no_base_bet
          | :missing_target
          | :insufficient_chips
          | :no_shooter
          | :not_shooter
          | :shooter_needs_line_bet

  # ── Client ──

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Subscribes the caller to table changes."
  def subscribe, do: PubSub.subscribe(Veejr.PubSub, @topic)

  @doc "The table as players see it."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc "Takes a seat, drawing or topping up the player's stack."
  @spec sit(User.t(), GenServer.server()) :: {:ok, map()} | {:error, error()}
  def sit(%User{} = user, server \\ __MODULE__), do: GenServer.call(server, {:sit, user})

  @doc """
  Seats an emailed guest.

  A guest's stack is drawn fresh and never written anywhere: there is no
  account to attach it to, so it lasts as long as the table does.
  """
  @spec sit_guest(term(), String.t(), GenServer.server()) :: {:ok, map()} | {:error, error()}
  def sit_guest(player_id, display_name, server \\ __MODULE__) do
    GenServer.call(server, {:sit_guest, player_id, display_name})
  end

  @doc "Leaves the table, refunding the stakes of any bets still unresolved."
  @spec leave(integer(), GenServer.server()) :: {:ok, map()}
  def leave(user_id, server \\ __MODULE__), do: GenServer.call(server, {:leave, user_id})

  @doc "Puts a bet on the felt."
  @spec place_bet(integer(), atom(), integer(), Bets.target(), GenServer.server()) ::
          {:ok, Bet.t()} | {:error, error()}
  def place_bet(user_id, bet_type, amount, target \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:place_bet, user_id, bet_type, amount, target})
  end

  @doc """
  Throws the dice.

  Only the shooter may, and only with a line bet down — otherwise a player
  with nothing at stake could shoot for everyone else.
  """
  @spec roll(integer(), GenServer.server()) :: {:ok, map()} | {:error, error()}
  def roll(user_id, server \\ __MODULE__), do: GenServer.call(server, {:roll, user_id})

  # ── Server ──

  @impl true
  def init(opts) do
    {:ok,
     %{
       players: %{},
       seat_order: [],
       shooter_id: nil,
       bets: [],
       game: State.new(),
       last_roll: nil,
       next_bet_id: 1,
       next_roll_id: 1,
       idle_timer: nil,
       idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms),
       roll_fn: Keyword.get(opts, :roll_fn, &Rng.roll/1)
     }}
  end

  @impl true
  def handle_info({:idle_shooter, user_id}, %{shooter_id: user_id} = state) do
    {:noreply, state |> release_seat(user_id) |> broadcast()}
  end

  def handle_info({:idle_shooter, _stale}, state), do: {:noreply, state}

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  def handle_call({:sit, %User{} = user}, _from, state) do
    cond do
      Map.has_key?(state.players, user.id) ->
        {:reply, {:ok, public(state)}, state}

      map_size(state.players) >= @max_players ->
        {:reply, {:error, :table_full}, state}

      true ->
        player = %{
          user_id: user.id,
          username: user.username,
          display_name: user.display_name,
          guest?: false,
          chips: Craps.take_seat_stack(user)
        }

        state = seat(state, player)
        {:reply, {:ok, public(state)}, broadcast(state)}
    end
  end

  def handle_call({:sit_guest, player_id, display_name}, _from, state) do
    cond do
      Map.has_key?(state.players, player_id) ->
        {:reply, {:ok, public(state)}, state}

      map_size(state.players) >= @max_players ->
        {:reply, {:error, :table_full}, state}

      true ->
        player = %{
          user_id: player_id,
          username: display_name,
          display_name: display_name,
          guest?: true,
          chips: Craps.starting_stack()
        }

        state = seat(state, player)
        {:reply, {:ok, public(state)}, broadcast(state)}
    end
  end

  def handle_call({:leave, user_id}, _from, state) do
    if Map.has_key?(state.players, user_id) do
      state = release_seat(state, user_id)
      {:reply, {:ok, public(state)}, broadcast(state)}
    else
      {:reply, {:ok, public(state)}, state}
    end
  end

  def handle_call({:place_bet, user_id, bet_type, amount, target}, _from, state) do
    with {:ok, player} <- fetch_player(state, user_id),
         :ok <- validate_bet(state, user_id, bet_type, amount, target) do
      replaced = replaced_odds(state, user_id, bet_type, target)
      net_cost = amount - if(replaced, do: replaced.amount, else: 0)

      if player.chips < net_cost do
        {:reply, {:error, :insufficient_chips}, state}
      else
        bet = %Bet{
          id: state.next_bet_id,
          player_id: user_id,
          type: bet_type,
          amount: amount,
          target: bet_target(bet_type, target, state)
        }

        chips = player.chips - net_cost
        Craps.put_chip_balance(user_id, chips)

        state = %{
          state
          | players: Map.put(state.players, user_id, %{player | chips: chips}),
            bets: Enum.reject(state.bets, &(replaced && &1.id == replaced.id)) ++ [bet],
            next_bet_id: state.next_bet_id + 1
        }

        {:reply, {:ok, bet}, broadcast(state)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:roll, user_id}, _from, state) do
    cond do
      is_nil(state.shooter_id) -> {:reply, {:error, :no_shooter}, state}
      state.shooter_id != user_id -> {:reply, {:error, :not_shooter}, state}
      not shooter_has_line_bet?(state) -> {:reply, {:error, :shooter_needs_line_bet}, state}
      true -> do_roll(state)
    end
  end

  defp do_roll(state) do
    weights = state |> dice_mode() |> Rng.weights_for()
    %{die1: die1, die2: die2, total: total} = state.roll_fn.(weights)

    {event, game} = State.apply_roll(state.game, die1, die2)

    # Bets resolve against the state the roll was thrown into, not the one it
    # produced: a come-out 7 pays the pass line before the round restarts.
    %{resolved: resolved, remaining: remaining, updates: updates} =
      Resolution.resolve_all(state.bets, die1, die2, state.game)

    players = Enum.reduce(resolved, state.players, &pay_out/2)

    last_roll = %{
      # Monotonic, so a browser can tell a fresh roll from a re-render of the
      # one it has already animated.
      id: state.next_roll_id,
      die1: die1,
      die2: die2,
      total: total,
      event: event,
      resolved: resolved,
      at: DateTime.utc_now(:second)
    }

    state = %{
      state
      | players: players,
        bets: remaining,
        game: game,
        last_roll: last_roll,
        next_roll_id: state.next_roll_id + 1
    }

    state = if event == :seven_out, do: advance_shooter(state), else: state

    {:reply, {:ok, Map.put(last_roll, :updates, updates)}, broadcast(reset_idle_timer(state))}
  end

  # The first person to sit picks up the dice.
  defp seat(state, player) do
    state = %{
      state
      | players: Map.put(state.players, player.user_id, player),
        seat_order: state.seat_order ++ [player.user_id]
    }

    if state.shooter_id do
      state
    else
      state |> Map.put(:shooter_id, player.user_id) |> reset_idle_timer()
    end
  end

  # Takes a player off the felt, refunding anything unresolved. Used both when
  # somebody leaves and when the idle timer takes the dice off an absent
  # shooter, so the two paths cannot drift apart.
  defp release_seat(state, user_id) do
    player = Map.fetch!(state.players, user_id)

    refund =
      state.bets
      |> Enum.filter(&(&1.player_id == user_id))
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    if refund > 0, do: Craps.put_chip_balance(user_id, player.chips + refund)

    state = %{
      state
      | players: Map.delete(state.players, user_id),
        seat_order: Enum.reject(state.seat_order, &(&1 == user_id)),
        bets: Enum.reject(state.bets, &(&1.player_id == user_id))
    }

    state = if state.shooter_id == user_id, do: advance_shooter(state), else: state

    # An empty table should not keep somebody else's point on the puck.
    if state.players == %{} do
      state
      |> Map.merge(%{game: State.new(), shooter_id: nil, last_roll: nil})
      |> reset_idle_timer()
    else
      state
    end
  end

  # The clock runs on whoever is holding the dice, and restarts whenever the
  # dice move or get thrown.
  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)

    timer =
      if state.shooter_id do
        Process.send_after(self(), {:idle_shooter, state.shooter_id}, state.idle_timeout_ms)
      end

    %{state | idle_timer: timer}
  end

  defp pay_out(%{player_id: player_id, payout: payout}, players) do
    case Map.fetch(players, player_id) do
      {:ok, player} when payout > 0 ->
        chips = player.chips + payout
        Craps.put_chip_balance(player_id, chips)
        Map.put(players, player_id, %{player | chips: chips})

      _otherwise ->
        players
    end
  end

  defp dice_mode(_state), do: AddOns.craps_dice_mode()

  defp fetch_player(state, user_id) do
    case Map.fetch(state.players, user_id) do
      {:ok, player} -> {:ok, player}
      :error -> {:error, :not_at_table}
    end
  end

  defp validate_bet(state, user_id, bet_type, amount, target) do
    cond do
      not Bets.type?(bet_type) -> {:error, :invalid_bet_type}
      not is_integer(amount) or amount <= 0 -> {:error, :invalid_amount}
      not Bets.placeable?(bet_type, state.game.phase) -> {:error, :invalid_phase}
      Bets.single?(bet_type) and holds?(state, user_id, bet_type) -> {:error, :duplicate_bet}
      true -> validate_odds(state, user_id, bet_type, target)
    end
  end

  defp validate_odds(state, user_id, bet_type, target) do
    case Bets.odds_base(bet_type) do
      nil ->
        :ok

      base ->
        cond do
          Bets.odds_needs_target?(bet_type) and is_nil(target) ->
            {:error, :missing_target}

          not has_base_bet?(state, user_id, base, bet_type, target) ->
            {:error, :no_base_bet}

          true ->
            :ok
        end
    end
  end

  defp has_base_bet?(state, user_id, base, bet_type, target) do
    Enum.any?(state.bets, fn bet ->
      bet.player_id == user_id and bet.type == base and
        (not Bets.odds_needs_target?(bet_type) or bet.target == target)
    end)
  end

  defp holds?(state, user_id, bet_type) do
    Enum.any?(state.bets, &(&1.player_id == user_id and &1.type == bet_type))
  end

  # Re-betting the odds adjusts the existing wager rather than stacking a
  # second one, so the old stake comes back off the cost of the new.
  defp replaced_odds(state, user_id, bet_type, target) do
    if Bets.odds_base(bet_type) do
      Enum.find(state.bets, fn bet ->
        bet.player_id == user_id and bet.type == bet_type and
          (not Bets.odds_needs_target?(bet_type) or bet.target == target)
      end)
    end
  end

  # Pass odds ride the table point even when the player did not name it.
  defp bet_target(:pass_odds, nil, state), do: state.game.point
  defp bet_target(:dont_pass_odds, nil, state), do: state.game.point
  defp bet_target(_bet_type, target, _state), do: target

  defp shooter_has_line_bet?(state) do
    Enum.any?(
      state.bets,
      &(&1.player_id == state.shooter_id and &1.type in [:pass_line, :dont_pass])
    )
  end

  defp advance_shooter(%{seat_order: []} = state),
    do: reset_idle_timer(%{state | shooter_id: nil})

  defp advance_shooter(state) do
    seated = Enum.filter(state.seat_order, &Map.has_key?(state.players, &1))

    state =
      case seated do
        [] ->
          %{state | shooter_id: nil, seat_order: []}

        seated ->
          next =
            case Enum.find_index(seated, &(&1 == state.shooter_id)) do
              nil -> hd(seated)
              index -> Enum.at(seated, rem(index + 1, length(seated)))
            end

          %{state | shooter_id: next, seat_order: seated}
      end

    reset_idle_timer(state)
  end

  defp broadcast(state) do
    PubSub.broadcast(Veejr.PubSub, @topic, {:craps_table, public(state)})
    state
  end

  defp public(state) do
    %{
      phase: state.game.phase,
      point: state.game.point,
      shooter_id: state.shooter_id,
      seats: Enum.map(state.seat_order, &Map.fetch!(state.players, &1)),
      bets: state.bets,
      last_roll: state.last_roll,
      max_players: @max_players
    }
  end
end
