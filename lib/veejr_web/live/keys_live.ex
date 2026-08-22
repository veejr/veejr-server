defmodule VeejrWeb.KeysLive do
  use VeejrWeb, :live_view

  alias Veejr.{Accounts, Federation, Messaging, Repo}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md">
        <%= if @user.public_key do %>
          <.header>
            Unlock your keys
            <:subtitle>
              Your secret key is stored encrypted. Enter your passphrase to unlock it
              for this browser session. The passphrase never leaves this device.
            </:subtitle>
          </.header>

          <form
            id="key-unlock"
            phx-hook="KeyUnlock"
            data-user-id={@user.id}
            data-enc-secret-key={@user.enc_secret_key}
            data-key-salt={@user.key_salt}
            data-key-nonce={@user.key_nonce}
            data-return-to={@return_to}
            class="mt-6 space-y-4"
          >
            <p data-role="error" class="hidden text-error text-sm"></p>
            <label for="key-unlock-passphrase" class="fieldset-label">Encryption passphrase</label>
            <.passphrase_input
              id="key-unlock-passphrase"
              role="passphrase"
              autocomplete="off"
            />
            <button type="submit" class="btn btn-primary w-full">Unlock</button>
          </form>

          <div class="mt-8 text-sm opacity-70">
            <p>Public key fingerprint:</p>
            <code class="break-all">{@user.public_key}</code>
          </div>

          <button
            id="key-lock"
            phx-hook="KeyLock"
            data-user-id={@user.id}
            class="btn btn-ghost btn-sm mt-6"
          >
            Lock this session
          </button>

          <div class="divider" />

          <section>
            <h2 class="text-lg font-semibold">Change passphrase</h2>
            <p class="text-sm opacity-70 mt-1">
              Re-wraps your secret key under a new passphrase. Your keypair — and all
              your history — is unchanged.
            </p>
            <form
              id="key-rewrap"
              phx-hook="KeyRewrap"
              data-user-id={@user.id}
              data-enc-secret-key={@user.enc_secret_key}
              data-key-salt={@user.key_salt}
              data-key-nonce={@user.key_nonce}
              class="mt-3 space-y-2"
            >
              <p data-role="error" class="hidden text-error text-sm"></p>
              <.passphrase_input
                id="key-rewrap-current"
                role="current"
                placeholder="current passphrase"
                compact
              />
              <.passphrase_input
                id="key-rewrap-next"
                role="next"
                placeholder="new passphrase (min 8 characters)"
                compact
              />
              <.passphrase_input
                id="key-rewrap-confirm"
                role="confirm"
                placeholder="confirm new passphrase"
                compact
              />
              <button type="submit" class="btn btn-sm">Change passphrase</button>
            </form>
          </section>

          <div class="divider" />

          <section>
            <h2 class="text-lg font-semibold">Rotate keys</h2>
            <p class="text-sm opacity-70 mt-1">
              Generates a brand-new keypair — do this if you suspect your keys were
              compromised. Your history is re-encrypted to the new key in this
              browser, and friends on other instances are asked to confirm your new
              key before they can reach you again.
            </p>
            <form
              id="key-rotate"
              phx-hook="KeyRotate"
              data-user-id={@user.id}
              data-enc-secret-key={@user.enc_secret_key}
              data-key-salt={@user.key_salt}
              data-key-nonce={@user.key_nonce}
              class="mt-3 space-y-2"
            >
              <p data-role="error" class="hidden text-error text-sm"></p>
              <.passphrase_input
                id="key-rotate-current"
                role="current"
                placeholder="current passphrase"
                compact
              />
              <.passphrase_input
                id="key-rotate-next"
                role="next"
                placeholder="new passphrase (min 8 characters)"
                compact
              />
              <button type="submit" class="btn btn-warning btn-sm">Rotate my keys</button>
            </form>
          </section>

          <div class="divider" />

          <details class="rounded-lg border border-error/40 p-4">
            <summary class="cursor-pointer font-semibold text-error">
              Lost your passphrase?
            </summary>
            <p class="text-sm opacity-70 mt-2">
              Without the passphrase your history cannot be recovered — that is the
              point of end-to-end encryption. Resetting creates fresh keys so you can
              keep using veejr, but <strong>everything you've received so far is
              permanently deleted</strong>. Friends on other instances must confirm
              your new key.
            </p>
            <form id="key-reset" phx-hook="KeyReset" data-user-id={@user.id} class="mt-3 space-y-2">
              <p data-role="error" class="hidden text-error text-sm"></p>
              <.passphrase_input
                id="key-reset-next"
                role="next"
                placeholder="new passphrase (min 8 characters)"
                compact
              />
              <.passphrase_input
                id="key-reset-confirm"
                role="confirm"
                placeholder="confirm new passphrase"
                compact
              />
              <button type="submit" class="btn btn-error btn-sm">
                Reset keys and delete received history
              </button>
            </form>
          </details>
        <% else %>
          <.header>
            Create your encryption keys
            <:subtitle>
              veejr encrypts everything end-to-end. Your keypair is generated here in
              your browser; the server only receives your public key and a copy of your
              secret key sealed with the passphrase below. Without the passphrase,
              nobody — including the server — can read your messages.
            </:subtitle>
          </.header>

          <form
            id="key-setup"
            phx-hook="KeySetup"
            data-user-id={@user.id}
            data-return-to={@return_to}
            class="mt-6 space-y-4"
          >
            <p data-role="error" class="hidden text-error text-sm"></p>
            <label for="key-setup-passphrase" class="fieldset-label">Encryption passphrase (min 8 characters)</label>
            <.passphrase_input
              id="key-setup-passphrase"
              role="passphrase"
              autocomplete="new-password"
            />
            <label for="key-setup-confirm" class="fieldset-label">Confirm passphrase</label>
            <.passphrase_input
              id="key-setup-confirm"
              role="confirm"
              autocomplete="new-password"
            />

            <section
              id="initial-password-setup"
              class="rounded-2xl border border-primary/20 bg-primary/5 p-4"
            >
              <h2 class="font-semibold">Add a login password (recommended)</h2>
              <p class="mt-1 text-sm text-base-content/70">
                A password lets you sign in directly next time instead of requesting another
                email link. It is separate from your encryption passphrase; use a password
                manager to create a strong, unique password.
              </p>
              <div class="mt-3">
                <.input
                  id="key-setup-password"
                  name="password"
                  value=""
                  type="password"
                  label="Login password (optional, 12–72 characters)"
                  autocomplete="new-password"
                  minlength="12"
                  maxlength="72"
                  data-role="account-password"
                />
                <.input
                  id="key-setup-password-confirmation"
                  name="password_confirmation"
                  value=""
                  type="password"
                  label="Confirm login password"
                  autocomplete="new-password"
                  minlength="12"
                  maxlength="72"
                  data-role="account-password-confirmation"
                />
              </div>
            </section>

            <button type="submit" class="btn btn-primary w-full">Generate my keys</button>
            <p class="text-xs opacity-70">
              Write your passphrase down. If you lose it, previously received messages
              cannot be recovered — that is the point.
            </p>
          </form>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       user: socket.assigns.current_scope.user,
       return_to: valid_return_to(params["return_to"]),
       page_title: "Keys"
     )}
  end

  attr :id, :string, required: true
  attr :role, :string, required: true
  attr :placeholder, :string, default: nil
  attr :autocomplete, :string, default: nil
  attr :compact, :boolean, default: false

  defp passphrase_input(assigns) do
    ~H"""
    <div
      id={"#{@id}-password-visibility"}
      class="relative"
      phx-hook="PasswordVisibility"
      phx-update="ignore"
    >
      <input
        id={@id}
        type="password"
        data-role={@role}
        placeholder={@placeholder}
        class={["input w-full !pr-12", @compact && "input-sm"]}
        autocomplete={@autocomplete}
        required
      />
      <button
        id={"#{@id}-password-visibility-toggle"}
        type="button"
        class="absolute right-1 top-1/2 z-10 flex size-10 -translate-y-1/2 items-center justify-center rounded-md text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        data-role="password-visibility-toggle"
        data-secret-label="passphrase"
        aria-label="Show passphrase"
        aria-pressed="false"
      >
        <span data-role="password-visibility-icon"><.icon name="hero-eye" class="size-5" /></span>
      </button>
    </div>
    """
  end

  @impl true
  def handle_event("keys_generated", params, socket) do
    password_params = Map.take(params, ["password", "password_confirmation"])
    key_params = Map.drop(params, ["password", "password_confirmation"])

    result =
      if Enum.any?(password_params, fn {_key, value} -> value != "" end) do
        Accounts.setup_user_keys_and_password(socket.assigns.user, key_params, password_params)
      else
        Accounts.setup_user_keys(socket.assigns.user, key_params)
      end

    case result do
      {:ok, _user} ->
        {:reply, %{ok: true},
         socket
         |> put_flash(:info, "Encryption keys created. Welcome to veejr!")
         |> push_navigate(to: socket.assigns.return_to || ~p"/")}

      {:error, :keys_already_set} ->
        {:reply, %{error: "Keys are already set for this account."}, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, %{error: key_setup_error(changeset)}, socket}
    end
  end

  def handle_event("unlocked", _params, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to || ~p"/")}
  end

  def handle_event("rewrap_keys", params, socket) do
    case Accounts.rewrap_user_keys(socket.assigns.user, params) do
      {:ok, user} ->
        {:reply, %{ok: true},
         socket |> assign(user: user) |> put_flash(:info, "Passphrase changed.")}

      {:error, _} ->
        {:reply, %{error: "Could not change the passphrase."}, socket}
    end
  end

  def handle_event("list_resealable", _params, socket) do
    {:reply, %{envelopes: Messaging.list_resealable(socket.assigns.user)}, socket}
  end

  def handle_event("rotate_keys", %{"keys" => keys, "envelopes" => envelopes} = params, socket) do
    result =
      Repo.transaction(fn ->
        {:ok, user} = Accounts.rotate_user_keys(socket.assigns.user, keys)
        {:ok, count} = Messaging.reseal_envelopes(user, envelopes)
        {user, count}
      end)

    case result do
      {:ok, {user, count}} ->
        Federation.announce_key_update(user)
        unreadable = params["unreadable"] || 0

        message =
          "Keys rotated; #{count} items re-encrypted." <>
            if(unreadable > 0,
              do: " #{unreadable} items could not be read and were left as-is.",
              else: ""
            )

        {:reply, %{ok: true}, socket |> assign(user: user) |> put_flash(:info, message)}

      _ ->
        {:reply, %{error: "Rotation failed — nothing was changed."}, socket}
    end
  end

  def handle_event("reset_keys", %{"keys" => keys}, socket) do
    result =
      Repo.transaction(fn ->
        {:ok, _count} = Messaging.purge_received_envelopes(socket.assigns.user)
        {:ok, user} = Accounts.rotate_user_keys(socket.assigns.user, keys)
        user
      end)

    case result do
      {:ok, user} ->
        Federation.announce_key_update(user)

        {:reply, %{ok: true},
         socket
         |> assign(user: user)
         |> put_flash(:info, "Fresh keys created. Received history was deleted.")}

      _ ->
        {:reply, %{error: "Reset failed — nothing was changed."}, socket}
    end
  end

  defp key_setup_error(changeset) do
    if Keyword.has_key?(changeset.errors, :password) or
         Keyword.has_key?(changeset.errors, :password_confirmation) do
      "Use a login password of 12–72 characters and make sure both entries match."
    else
      "Could not store keys — please try again."
    end
  end

  defp valid_return_to(path) when is_binary(path) do
    uri = URI.parse(path)

    if uri.scheme == nil and uri.host == nil and String.starts_with?(uri.path || "", "/") and
         not String.starts_with?(path, "//") do
      path
    end
  end

  defp valid_return_to(_path), do: nil
end
