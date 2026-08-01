defmodule Veejr.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Veejr.Repo

  alias Veejr.Accounts.{
    ApiDeviceSession,
    ApiRefreshTokenHistory,
    Invitation,
    InstanceAdministration,
    Scope,
    User,
    UserAvatar,
    UserNotifier,
    UserToken
  }

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.one(
      from(u in User, where: u.email == ^normalize_login_identifier(email) and is_nil(u.host))
    )
  end

  @doc """
  Gets a local user by either their email address or username.

  Remote users are intentionally excluded: their rows support federation and
  must never be usable to authenticate with this instance.
  """
  def get_user_by_login_identifier(identifier) when is_binary(identifier) do
    identifier = normalize_login_identifier(identifier)

    Repo.one(
      from(u in User,
        where: is_nil(u.host) and (u.email == ^identifier or u.username == ^identifier)
      )
    )
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_login_identifier(email)
    if account_active?(user) and User.valid_password?(user, password), do: user
  end

  @doc "Returns whether a local account is allowed to authenticate."
  def account_active?(%User{suspended_at: nil}), do: true
  def account_active?(_user), do: false

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Returns the public URL for a user's uploaded avatar, or nil for the placeholder."
  def avatar_url(%User{
        host: nil,
        has_avatar: true,
        avatar_version: version,
        username: username
      })
      when is_integer(version) and version > 0 do
    "/avatars/#{URI.encode(username)}?v=#{version}"
  end

  def avatar_url(%User{
        host: host,
        has_avatar: true,
        avatar_version: version,
        username: username
      })
      when is_binary(host) and is_integer(version) and version > 0 do
    Veejr.Federation.Client.base_url(host) <>
      "/avatars/#{URI.encode(username)}?v=#{version}"
  end

  def avatar_url(_user), do: nil

  @doc "Stores a browser-normalized 512px JPEG as the user's public avatar."
  def put_user_avatar(%User{} = user, data) when is_binary(data) do
    with :ok <- Veejr.Accounts.Avatar.validate(data) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :avatar,
        UserAvatar.changeset(%UserAvatar{}, %{user_id: user.id, image: data}),
        on_conflict: [set: [image: data, updated_at: DateTime.utc_now(:second)]],
        conflict_target: :user_id
      )
      |> Ecto.Multi.update(
        :user,
        User.avatar_changeset(user, %{
          has_avatar: true,
          avatar_version: (user.avatar_version || 0) + 1
        })
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{user: updated_user}} -> {:ok, updated_user}
        {:error, _operation, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc "Removes a user's avatar and advances its cache version."
  def remove_user_avatar(%User{} = user) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete_all(:avatar, from(a in UserAvatar, where: a.user_id == ^user.id))
    |> Ecto.Multi.update(
      :user,
      User.avatar_changeset(user, %{
        has_avatar: false,
        avatar_version: (user.avatar_version || 0) + 1
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{user: updated_user}} -> {:ok, updated_user}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Turns the user's online status on or off for their friends.

  Switching off drops the live presence record immediately rather than
  waiting for their open tabs to close, so the setting takes effect while
  they are still looking at it.
  """
  def set_presence_sharing(%User{} = user, sharing?) when is_boolean(sharing?) do
    user
    |> User.presence_changeset(%{presence_sharing: sharing?})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        if sharing?, do: Veejr.Presence.track(updated), else: Veejr.Presence.untrack(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc false
  def get_user_avatar_image(%User{id: user_id}) do
    Repo.one(from(a in UserAvatar, where: a.user_id == ^user_id, select: a.image))
  end

  @doc "Returns the permanently assigned administrator for this instance, if one exists."
  def get_instance_admin do
    Repo.one(
      from(a in InstanceAdministration,
        where: a.id == 1,
        join: user in assoc(a, :admin_user),
        select: user
      )
    )
  end

  @doc "Returns whether the local user is this instance's permanent administrator."
  def instance_admin?(%User{id: user_id}) do
    Repo.exists?(
      from(a in InstanceAdministration, where: a.id == 1 and a.admin_user_id == ^user_id)
    )
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @invite_salt "veejr invite"
  @invite_max_age_seconds 7 * 24 * 60 * 60

  def register_user(attrs, invite_token \\ nil) do
    invitation = get_open_invitation(invite_token)
    tracked_invitation = invitation || get_tracked_invitation(invite_token)
    registration_policy = Veejr.InstanceSettings.registration_policy()

    cond do
      invitation && registration_policy != "closed" ->
        register_invited_user(attrs, invitation)

      invitation ->
        {:error, :registration_closed}

      tracked_invitation ->
        {:error, :invite_unavailable}

      Veejr.registration_open?() or
          (registration_policy != "closed" and valid_legacy_invite?(invite_token)) ->
        register_open_user(attrs)

      true ->
        {:error, :registration_closed}
    end
  end

  defp register_open_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  defp register_invited_user(attrs, invitation) do
    now = DateTime.utc_now(:second)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Ecto.Multi.run(:invitation, fn repo, %{user: user} ->
      {count, _} =
        repo.update_all(
          from(i in Invitation,
            where: i.id == ^invitation.id and is_nil(i.accepted_at) and i.expires_at > ^now
          ),
          set: [accepted_by_id: user.id, accepted_at: now, updated_at: now]
        )

      if count == 1, do: {:ok, invitation}, else: {:error, :invite_unavailable}
    end)
    |> Ecto.Multi.insert(:friendship, fn %{user: user} ->
      Veejr.Social.Friendship.changeset(%Veejr.Social.Friendship{}, %{
        requester_id: invitation.inviter_id,
        addressee_id: user.id,
        status: "accepted"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        UserNotifier.deliver_invitation_accepted(invitation.inviter, user)
        {:ok, user}

      {:error, :user, changeset, _changes} ->
        {:error, changeset}

      {:error, _operation, _reason, _changes} ->
        {:error, :invite_unavailable}
    end
  end

  @doc """
  An invite link lets a personal (closed-registration) instance host more
  people — a family or group sharing one server. Tokens are signed, carry the
  inviting user's id, and expire after a week.
  """
  def generate_invite(%User{id: id}) do
    Phoenix.Token.sign(VeejrWeb.Endpoint, @invite_salt, id)
  end

  @doc "Creates a tracked, single-use invitation using the configured lifetime."
  def create_invitation(%User{} = inviter) do
    if Veejr.InstanceSettings.registration_policy() == "closed" do
      {:error, :invitations_closed}
    else
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      lifetime = Veejr.InstanceSettings.invitation_lifetime_hours() * 60 * 60

      attrs = %{
        inviter_id: inviter.id,
        token_hash: invitation_token_hash(token),
        expires_at: DateTime.add(DateTime.utc_now(:second), lifetime, :second)
      }

      case Repo.insert(Invitation.changeset(%Invitation{}, attrs)) do
        {:ok, invitation} -> {:ok, invitation, token}
        error -> error
      end
    end
  end

  @doc "Returns an unexpired, unused tracked invitation with its inviter."
  def get_open_invitation(token) when is_binary(token) and byte_size(token) > 0 do
    now = DateTime.utc_now(:second)
    token_hash = invitation_token_hash(token)

    Repo.one(
      from(i in Invitation,
        where:
          i.token_hash == ^token_hash and is_nil(i.accepted_at) and is_nil(i.revoked_at) and
            i.expires_at > ^now,
        preload: [:inviter]
      )
    )
  end

  def get_open_invitation(_token), do: nil

  defp get_tracked_invitation(token) when is_binary(token) and byte_size(token) > 0 do
    token_hash = invitation_token_hash(token)
    Repo.one(from(i in Invitation, where: i.token_hash == ^token_hash))
  end

  defp get_tracked_invitation(_token), do: nil

  @doc "Lists invitation acceptances that the inviter has not dismissed."
  def list_unseen_invitation_acceptances(%User{id: inviter_id}) do
    Repo.all(
      from(i in Invitation,
        where: i.inviter_id == ^inviter_id and not is_nil(i.accepted_at) and is_nil(i.seen_at),
        order_by: [desc: i.accepted_at],
        preload: [:accepted_by]
      )
    )
  end

  @doc "Dismisses one joined-from-invitation notice owned by the inviter."
  def dismiss_invitation_acceptance(%User{id: inviter_id}, invitation_id) do
    case Repo.get_by(Invitation, id: invitation_id, inviter_id: inviter_id) do
      nil ->
        {:error, :not_found}

      invitation ->
        invitation
        |> Ecto.Changeset.change(seen_at: DateTime.utc_now(:second))
        |> Repo.update()
    end
  end

  def valid_invite?(nil), do: false

  def valid_invite?(token) when is_binary(token) do
    get_open_invitation(token) != nil or valid_legacy_invite?(token)
  end

  defp valid_legacy_invite?(nil), do: false

  defp valid_legacy_invite?(token) when is_binary(token) do
    case Phoenix.Token.verify(VeejrWeb.Endpoint, @invite_salt, token,
           max_age: @invite_max_age_seconds
         ) do
      {:ok, inviter_id} -> Repo.get(User, inviter_id) != nil
      _ -> false
    end
  end

  defp invitation_token_hash(token) do
    :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns a changeset for the registration form (email + username).
  """
  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  @doc """
  Gets a *local* user by username (the public handle used for friend lookup
  and the federation directory). Remote users share the table but are only
  ever addressed together with their host.
  """
  def get_user_by_username(username) when is_binary(username) do
    Repo.one(from(u in User, where: u.username == ^username and is_nil(u.host)))
  end

  @doc """
  Stores client-generated E2E key material for the user.

  Refuses to overwrite existing keys: replacing the keypair would make all
  previously received ciphertext undecryptable, so key rotation must be an
  explicit, separate operation.
  """
  def setup_user_keys(user, attrs) do
    if user.public_key do
      {:error, :keys_already_set}
    else
      user
      |> User.keys_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc "Stores first-time encryption keys and a login password in one update."
  def setup_user_keys_and_password(user, key_attrs, password_attrs) do
    if user.public_key do
      {:error, :keys_already_set}
    else
      user
      |> User.keys_and_password_changeset(key_attrs, password_attrs)
      |> Repo.update()
    end
  end

  @doc """
  Passphrase change: replaces only the wrapped secret key (re-wrapped
  client-side under the new passphrase). The keypair itself is unchanged, so
  nothing else in the system is affected.
  """
  def rewrap_user_keys(%User{public_key: pk} = user, attrs) when is_binary(pk) do
    user
    |> Ecto.Changeset.cast(attrs, [:enc_secret_key, :key_salt, :key_nonce])
    |> Ecto.Changeset.validate_required([:enc_secret_key, :key_salt, :key_nonce])
    |> Repo.update()
  end

  @doc """
  Key rotation/reset: replaces the whole keypair. Callers are responsible for
  what happens to existing ciphertext (re-encrypt on rotation, purge on
  reset) and for announcing the change to remote friends.
  """
  def rotate_user_keys(%User{} = user, attrs) do
    user
    |> User.keys_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Permanently deletes a user account.

  Foreign keys cascade: envelopes the user sent (including copies held for
  recipients — the sender owns their data and deletion withdraws it),
  envelopes they received, friendships, group memberships, notifications, and
  session tokens all go. Attachment files are removed from disk first.
  """
  def delete_user(%User{} = user) do
    if instance_admin?(user) do
      {:error, :instance_admin}
    else
      Veejr.Messaging.purge_blob_files(user)
      Repo.delete(user)
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Veejr.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Veejr.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user, attrs \\ %{}) do
    {token, user_token} = UserToken.build_session_token(user, attrs)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    if account_active?(user) do
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")
      Repo.insert!(user_token)
      UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
    else
      {:ok, :suppressed}
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  def user_session_id(token) when is_binary(token) do
    from(session in UserToken,
      where: session.token == ^token and session.context == "session",
      select: session.id
    )
    |> Repo.one()
  end

  def user_session_id(_token), do: nil

  def touch_user_session_token(token) when is_binary(token) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -5, :minute)

    from(session in UserToken,
      where:
        session.token == ^token and session.context == "session" and
          (is_nil(session.last_used_at) or session.last_used_at < ^cutoff)
    )
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now(:second)])

    :ok
  end

  def list_device_sessions(%Scope{user: %User{id: user_id}}, current_web_session_id \\ nil) do
    web =
      from(session in UserToken,
        where: session.user_id == ^user_id and session.context == "session",
        order_by: [desc: session.last_used_at, desc: session.inserted_at]
      )
      |> Repo.all()
      |> Enum.map(fn session ->
        %{
          id: session.id,
          kind: "web",
          name: session.device_name || "Web browser",
          platform: "Browser",
          app_version: nil,
          inserted_at: session.inserted_at,
          last_used_at: session.last_used_at || session.inserted_at,
          current: session.id == current_web_session_id
        }
      end)

    android =
      from(session in ApiDeviceSession,
        where: session.user_id == ^user_id,
        order_by: [desc: session.last_used_at, desc: session.inserted_at]
      )
      |> Repo.all()
      |> Enum.map(fn session ->
        %{
          id: session.id,
          kind: "android",
          name: session.device_name,
          platform: "Android",
          app_version: session.app_version,
          inserted_at: session.inserted_at,
          last_used_at: session.last_used_at,
          current: false
        }
      end)

    web ++ android
  end

  def revoke_device_session(
        %Scope{user: %User{id: user_id}},
        "web",
        session_id,
        current_web_session_id
      ) do
    with {:ok, id} <- parse_positive_id(session_id),
         false <- id == current_web_session_id do
      {count, _} =
        from(session in UserToken,
          where:
            session.id == ^id and session.user_id == ^user_id and
              session.context == "session"
        )
        |> Repo.delete_all()

      if count == 1, do: :ok, else: {:error, :not_found}
    else
      true -> {:error, :current_session}
      :error -> {:error, :not_found}
    end
  end

  def revoke_device_session(%Scope{} = scope, "android", session_id, _current_web_session_id) do
    with {:ok, id} <- parse_positive_id(session_id) do
      delete_api_device_session(scope, id)
    else
      :error -> {:error, :not_found}
    end
  end

  def revoke_device_session(_scope, _kind, _session_id, _current_web_session_id),
    do: {:error, :not_found}

  ## Native API device sessions

  def create_api_device_session(%User{} = user, attrs) when is_map(attrs) do
    if account_active?(user) do
      {changeset, tokens} = ApiDeviceSession.create_changeset(%ApiDeviceSession{}, user, attrs)

      case Repo.insert(changeset) do
        {:ok, session} ->
          {:ok, session, Map.put(tokens, :device_session_id, to_string(session.id))}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :suspended}
    end
  end

  def get_user_and_api_session_by_access_token(token) when is_binary(token) do
    with {:ok, token_hash} <- ApiDeviceSession.hash_token(token) do
      now = DateTime.utc_now(:second)

      from(session in ApiDeviceSession,
        join: user in assoc(session, :user),
        where: session.access_token_hash == ^token_hash,
        where: session.access_expires_at > ^now,
        where: is_nil(user.suspended_at),
        select: {%{user | authenticated_at: session.authenticated_at}, session}
      )
      |> Repo.one()
    else
      :error -> nil
    end
  end

  def rotate_api_device_session(refresh_token) when is_binary(refresh_token) do
    with {:ok, token_hash} <- ApiDeviceSession.hash_token(refresh_token) do
      Repo.transaction(
        fn ->
          now = DateTime.utc_now(:second)

          session =
            Repo.one(
              from session in ApiDeviceSession,
                join: user in assoc(session, :user),
                where: session.refresh_token_hash == ^token_hash,
                where: session.refresh_expires_at > ^now,
                where: is_nil(user.suspended_at),
                select: session
            )

          case session do
            %ApiDeviceSession{} = session ->
              %ApiRefreshTokenHistory{}
              |> ApiRefreshTokenHistory.changeset(session, session.refresh_token_hash)
              |> Repo.insert!()

              {changeset, tokens} = ApiDeviceSession.rotate_changeset(session, now)

              case Repo.update(changeset) do
                {:ok, session} ->
                  {:rotated, session, Map.put(tokens, :device_session_id, to_string(session.id))}

                {:error, changeset} ->
                  Repo.rollback(changeset)
              end

            nil ->
              case revoke_reused_refresh_token(token_hash) do
                1 -> :reused
                0 -> Repo.rollback(:invalid_refresh_token)
              end
          end
        end,
        mode: :immediate
      )
      |> case do
        {:ok, {:rotated, session, tokens}} -> {:ok, {session, tokens}}
        {:ok, :reused} -> {:error, :invalid_refresh_token}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_refresh_token}
    end
  end

  def delete_api_device_session(%Scope{user: %User{id: user_id}}, session_id) do
    {count, _} =
      from(session in ApiDeviceSession,
        where: session.id == ^session_id and session.user_id == ^user_id
      )
      |> Repo.delete_all()

    if count == 1, do: :ok, else: {:error, :not_found}
  end

  defp normalize_login_identifier(identifier) do
    identifier
    |> String.trim()
    |> String.downcase()
  end

  defp parse_positive_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_positive_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_positive_id(_id), do: :error

  defp revoke_reused_refresh_token(token_hash) do
    case Repo.get_by(ApiRefreshTokenHistory, token_hash: token_hash) do
      %ApiRefreshTokenHistory{api_device_session_id: session_id} ->
        {count, _} =
          Repo.delete_all(from(session in ApiDeviceSession, where: session.id == ^session_id))

        count

      nil ->
        0
    end
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
