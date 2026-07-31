defmodule Veejr.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :suspended_at, :utc_datetime
    belongs_to :suspended_by, __MODULE__

    field :username, :string
    field :display_name, :string
    field :has_avatar, :boolean, default: false
    field :avatar_version, :integer, default: 0

    # nil for local accounts; a remote user's home-instance authority
    # (e.g. "veejr.example.com", "localhost:4001") otherwise. Remote users
    # never log in here — they exist so friendships and envelopes can
    # reference them and so their pinned public key is at hand.
    field :host, :string

    # E2E key material: the secret key is encrypted in the browser with a
    # passphrase-derived key before upload. The server cannot decrypt it.
    field :public_key, :string
    field :enc_secret_key, :string, redact: true
    field :key_salt, :string
    field :key_nonce, :string

    # For remote contacts only: a key change their instance announced, held
    # here until a human confirms it on the Friends page.
    field :pending_public_key, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for registration: email plus the public handle.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :username, :display_name])
    |> validate_email(opts)
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[a-z0-9_]{3,30}$/,
      message: "must be 3-30 characters: lowercase letters, digits, underscore"
    )
    |> validate_length(:display_name, max: 80)
    |> validate_username_available()
    |> unique_constraint(:username, name: :users_username_host_index)
  end

  # Registration creates local users (host: nil); uniqueness is per-host, so
  # check availability among local users explicitly rather than via
  # unsafe_validate_unique (which can't express the nil-host scope).
  defp validate_username_available(changeset) do
    username = get_change(changeset, :username)

    if username && Veejr.Accounts.get_user_by_username(username) do
      add_error(changeset, :username, "has already been taken")
    else
      changeset
    end
  end

  @doc """
  A changeset for storing client-generated E2E key material.

  All values are base64 strings produced in the browser; the secret key
  arrives already encrypted with the user's passphrase-derived key.
  """
  def keys_changeset(user, attrs) do
    user
    |> cast(attrs, [:public_key, :enc_secret_key, :key_salt, :key_nonce])
    |> validate_required([:public_key, :enc_secret_key, :key_salt, :key_nonce])
    |> validate_length(:public_key, max: 100)
    |> validate_length(:enc_secret_key, max: 200)
  end

  @doc "A changeset for replacing or removing a user's public profile image."
  def avatar_changeset(user, attrs) do
    user
    |> cast(attrs, [:has_avatar, :avatar_version])
    |> validate_number(:avatar_version, greater_than_or_equal_to: 0)
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Veejr.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  @doc "A changeset that stores initial encryption keys and a login password atomically."
  def keys_and_password_changeset(user, key_attrs, password_attrs) do
    user
    |> keys_changeset(key_attrs)
    |> password_changeset(password_attrs)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Veejr.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
