defmodule Veejr.AddOns.Craps do
  @moduledoc """
  Chip stacks for the craps add-on.

  Chips are play money and never leave the table — there is nothing to buy
  them with and nothing to cash them out for.

  A member who sits down broke is topped back up to the starting stack. This
  is deliberate: the alternative is a player permanently stuck at zero waiting
  on an administrator, which is the wrong shape for a game friends play for
  fun.

  An administrator can also set a stack outright, for the cases that does not
  cover — see `Veejr.Admin.set_craps_chips/3`. Unlike the reference
  implementation's `/admin/give-chips`, that one is authorized and audited.
  """

  import Ecto.Query, warn: false

  alias Veejr.AddOns.Craps.{Guest, Player}
  alias Veejr.Accounts.User
  alias Veejr.Repo

  @starting_stack 1000
  @guest_lifetime_seconds 24 * 60 * 60

  # ── Emailed guests ──────────────────────────────────────────────────────────

  @doc "Changeset for the host's invite-a-guest form."
  def change_guest_invitation(attrs \\ %{}),
    do: Guest.invitation_changeset(%Guest{}, attrs)

  @doc """
  Creates one single-use capability to play as a guest, returning the raw
  token to put in the email. Only the hash is kept.
  """
  @spec invite_guest(User.t(), map()) ::
          {:ok, Guest.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def invite_guest(%User{host: nil} = host, attrs) do
    token = random_token()

    attrs = %{
      host_id: host.id,
      invited_email: Map.get(attrs, "invited_email") || Map.get(attrs, :invited_email),
      public_id: random_token(),
      token_hash: token_hash(token),
      expires_at: DateTime.add(DateTime.utc_now(:second), @guest_lifetime_seconds, :second)
    }

    case %Guest{} |> Guest.create_changeset(attrs) |> Repo.insert() do
      {:ok, guest} -> {:ok, Repo.preload(guest, :host), token}
      error -> error
    end
  end

  @doc "The live capability behind a token, or nil once it has expired."
  @spec guest_by_token(String.t()) :: Guest.t() | nil
  def guest_by_token(token) when is_binary(token) and byte_size(token) > 0 do
    now = DateTime.utc_now(:second)

    Guest
    |> where([g], g.token_hash == ^token_hash(token) and g.expires_at > ^now)
    |> preload(:host)
    |> Repo.one()
  end

  def guest_by_token(_token), do: nil

  @doc "Names a guest as they sit down."
  def name_guest(%Guest{} = guest, display_name) do
    guest
    |> Guest.name_changeset(%{display_name: display_name})
    |> Repo.update()
  end

  @doc "Guests this host has invited, newest first."
  def list_guests(%User{id: host_id}) do
    Guest
    |> where([g], g.host_id == ^host_id and g.expires_at > ^DateTime.utc_now(:second))
    |> order_by([g], desc: g.inserted_at)
    |> Repo.all()
  end

  @doc """
  Records that a guest has taken up the offer of an account.

  Guarded so that one capability yields at most one membership invitation,
  which is why this lives in the database rather than in the table process.
  """
  def mark_guest_joined(%Guest{joined_at: nil} = guest) do
    guest
    |> Ecto.Changeset.change(joined_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  def mark_guest_joined(%Guest{} = guest), do: {:error, {:already_joined, guest}}

  @doc "The table seat key for a guest, distinct from any member's user id."
  def guest_player_id(%Guest{public_id: public_id}), do: "guest:" <> public_id

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

  @doc """
  Asks a friend to come and play.

  Lands as a banner on whatever page they have open, on the same per-user
  topic the encrypted-item notifications use. Nothing is stored: this is
  "we're playing now", not an invitation with a lifetime. Somebody who is
  offline simply misses it.
  """
  @spec invite(User.t(), User.t()) :: :ok | {:error, :not_friends}
  def invite(%User{} = host, %User{} = friend) do
    if Veejr.Social.friends?(host.id, friend.id) do
      Phoenix.PubSub.broadcast(
        Veejr.PubSub,
        "user:#{friend.id}",
        {:craps_invite, host.display_name || "@#{host.username}"}
      )
    else
      {:error, :not_friends}
    end
  end

  @doc "The stack a player starts, and is topped back up to when broke."
  def starting_stack, do: @starting_stack

  @doc """
  The member's stack, creating it at the starting amount the first time and
  topping it back up if they have gone broke.
  """
  @spec take_seat_stack(User.t()) :: non_neg_integer()
  def take_seat_stack(%User{id: user_id}) do
    case Repo.get_by(Player, user_id: user_id) do
      nil ->
        %Player{}
        |> Player.changeset(%{user_id: user_id, chip_balance: @starting_stack})
        |> Repo.insert!()

        @starting_stack

      %Player{chip_balance: 0} = player ->
        player
        |> Player.changeset(%{chip_balance: @starting_stack})
        |> Repo.update!()

        @starting_stack

      %Player{chip_balance: balance} ->
        balance
    end
  end

  @doc "The member's stack without creating or topping one up."
  @spec chip_balance(User.t() | integer()) :: non_neg_integer()
  def chip_balance(%User{id: user_id}), do: chip_balance(user_id)

  def chip_balance(user_id) when is_integer(user_id) do
    case Repo.get_by(Player, user_id: user_id) do
      nil -> 0
      player -> player.chip_balance
    end
  end

  @doc """
  Whether a seat belongs to a member rather than an emailed guest.

  Members are keyed by their user id and guests by an opaque string, and that
  is the whole of the difference as far as the table is concerned: a guest
  has no row to write a stack to, so their chips live and die with the table.
  """
  @spec member?(term()) :: boolean()
  def member?(player_id), do: is_integer(player_id)

  @doc "Writes a member's stack back after the table has settled a roll."
  @spec put_chip_balance(term(), non_neg_integer()) :: :ok
  def put_chip_balance(player_id, _balance) when not is_integer(player_id), do: :ok

  def put_chip_balance(user_id, balance) when is_integer(user_id) and balance >= 0 do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      Player,
      [[user_id: user_id, chip_balance: balance, inserted_at: now, updated_at: now]],
      on_conflict: [set: [chip_balance: balance, updated_at: now]],
      conflict_target: :user_id
    )

    :ok
  end
end
