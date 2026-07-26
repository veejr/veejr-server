defmodule VeejrWeb.UserLive.Settings do
  use VeejrWeb, :live_view

  on_mount {VeejrWeb.UserAuth, :require_sudo_mode}

  alias Veejr.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <section class="mt-8">
        <h2 class="text-lg font-semibold">Profile image</h2>
        <div class="mt-3 flex flex-col gap-4 sm:flex-row sm:items-center">
          <div class="relative size-28 shrink-0">
            <.user_avatar
              id="settings-avatar"
              user={@current_scope.user}
              class="size-28 text-2xl"
              on_click="open_profile"
            />
            <img
              data-role="avatar-preview"
              alt="Selected profile image preview"
              class="pointer-events-none absolute inset-0 size-28 rounded-full object-cover opacity-0 has-[src]:opacity-100 ring-2 ring-base-100 shadow-sm"
            />
          </div>
          <form id="avatar-upload" phx-hook="AvatarUpload" class="min-w-0 flex-1 space-y-3">
            <p class="text-sm opacity-70">
              Choose a photo and veejr will crop it to fit throughout the app.
            </p>
            <input
              type="file"
              accept="image/jpeg,image/png,image/webp,image/gif"
              class="file-input file-input-bordered file-input-sm w-full max-w-md"
            />
            <div class="flex flex-wrap items-center gap-2">
              <button type="submit" class="btn btn-primary btn-sm">
                <.icon name="hero-photo" class="size-4" /> Use this image
              </button>
              <button
                :if={@current_scope.user.has_avatar}
                type="button"
                phx-click="remove_avatar"
                data-confirm="Remove your profile image and use the placeholder?"
                class="btn btn-ghost btn-sm"
              >
                Remove
              </button>
            </div>
            <p data-role="avatar-status" class="min-h-5 text-sm opacity-70"></p>
          </form>
        </div>
      </section>

      <div class="divider" />

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <section id="push-setup" phx-hook="PushSetup" data-vapid-key={@vapid_key}>
        <h2 class="text-lg font-semibold">Push notifications</h2>
        <p class="mt-1 text-sm opacity-70">
          Get notified on this device even when veejr isn't open. Pushes carry only
          who sent something and what kind — never the content, which stays put until
          you request it.
          <span :if={@push_devices > 0}>
            Currently enabled on {@push_devices} device{if @push_devices != 1, do: "s"}.
          </span>
        </p>
        <button type="button" data-role="push-enable" class="btn btn-outline btn-sm mt-3">
          Enable push on this device
        </button>
        <button
          id="install-app"
          phx-hook="InstallApp"
          type="button"
          class="btn btn-outline btn-sm mt-3 ml-2 hidden"
        >
          📱 Install veejr as an app
        </button>
        <p data-role="push-status" class="mt-2 text-sm opacity-70"></p>
      </section>

      <div class="divider" />

      <section
        id="account-backup"
        class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm"
      >
        <div class="border-b border-base-300 bg-gradient-to-br from-primary/10 via-base-100 to-secondary/10 px-5 py-5 sm:px-6">
          <div class="flex items-start gap-3">
            <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/15 text-primary">
              <.icon name="hero-archive-box-arrow-down" class="size-5" />
            </span>
            <div>
              <h2 class="text-lg font-semibold tracking-tight">Backup and restore</h2>
              <p class="mt-1 max-w-2xl text-sm leading-6 text-base-content/70">
                Keep a private copy of your profile, wrapped encryption keys, contacts,
                encrypted message history, and uploaded encrypted attachments.
              </p>
            </div>
          </div>
        </div>

        <div class="grid gap-6 p-5 sm:p-6 lg:grid-cols-2">
          <div>
            <h3 class="font-semibold">Export a backup</h3>
            <p class="mt-1 text-sm leading-6 text-base-content/65">
              Your passphrase is still required to unlock encrypted content. The archive
              reveals account and social metadata, so store it somewhere private.
            </p>
            <.link
              id="export-account-backup"
              href={~p"/export"}
              class="mt-4 inline-flex items-center gap-2 rounded-xl bg-primary px-4 py-2.5 text-sm font-semibold text-primary-content shadow-sm transition hover:-translate-y-0.5 hover:shadow-md"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download backup
            </.link>
          </div>

          <div class="border-t border-base-300 pt-6 lg:border-l lg:border-t-0 lg:pl-6 lg:pt-0">
            <h3 class="font-semibold">Restore this account</h3>
            <p class="mt-1 text-sm leading-6 text-base-content/65">
              Restore missing data from a backup of this exact account. Existing data is
              kept, and your login and encryption keys are never replaced.
            </p>

            <.form
              for={@backup_form}
              id="restore-backup-form"
              phx-change="validate_backup"
              phx-submit="restore_backup"
              class="mt-4 space-y-3"
            >
              <label
                for={@uploads.backup.ref}
                class="group flex cursor-pointer items-center gap-3 rounded-xl border border-dashed border-base-300 bg-base-200/40 px-4 py-3 transition hover:border-primary/60 hover:bg-primary/5"
              >
                <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-base-100 shadow-sm">
                  <.icon name="hero-document-arrow-up" class="size-5 text-primary" />
                </span>
                <span class="min-w-0">
                  <span class="block truncate text-sm font-medium">
                    {backup_upload_label(@uploads.backup.entries)}
                  </span>
                  <span class="block text-xs text-base-content/55">Veejr .zip backup</span>
                </span>
                <.live_file_input upload={@uploads.backup} class="sr-only" />
              </label>

              <%= for entry <- @uploads.backup.entries,
                      error <- upload_errors(@uploads.backup, entry) do %>
                <p class="text-sm text-error">{backup_upload_error(error)}</p>
              <% end %>

              <button
                id="restore-account-backup"
                type="submit"
                disabled={@uploads.backup.entries == []}
                phx-disable-with="Restoring…"
                class="inline-flex items-center gap-2 rounded-xl border border-base-300 bg-base-100 px-4 py-2.5 text-sm font-semibold shadow-sm transition hover:border-primary/50 hover:text-primary disabled:cursor-not-allowed disabled:opacity-45"
              >
                <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Restore backup
              </button>
            </.form>
          </div>
        </div>
      </section>

      <section :if={
        Veejr.instance_mode() == :personal and
          Veejr.InstanceSettings.registration_policy() != "closed"
      }>
        <div class="divider" />
        <h2 class="text-lg font-semibold">Invite someone to this instance</h2>
        <p class="mt-1 text-sm opacity-70">
          Registration on a personal instance is closed, but you can host family or
          friends here: an invite link lets one more person register.
        </p>
        <button phx-click="generate_invite" class="btn btn-outline btn-sm mt-3">
          Generate invite link
        </button>
        <p :if={@invite_url} class="mt-2 text-sm">
          <code class="break-all select-all">{@invite_url}</code>
        </p>
      </section>

      <div class="divider" />

      <section class="rounded-lg border border-error/40 p-4">
        <h2 class="text-lg font-semibold text-error">Danger zone</h2>
        <p :if={@instance_admin} id="admin-account-protection" class="mt-1 text-sm opacity-70">
          This account is the permanent instance administrator and cannot be deleted.
        </p>
        <p :if={!@instance_admin} class="mt-1 text-sm opacity-70">
          Deleting your account is permanent. It also withdraws every message,
          location, and note you ever sent — your data leaves with you. Export first
          if you want to keep your history.
        </p>
        <button
          :if={!@instance_admin}
          phx-click="delete_account"
          data-confirm="Permanently delete your account? This withdraws everything you've sent and cannot be undone."
          class="btn btn-error btn-sm mt-3"
        >
          Delete my account
        </button>
      </section>

      <.profile_dialog user={@selected_profile} editable={false} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:instance_admin, Accounts.instance_admin?(user))
      |> assign(:selected_profile, nil)
      |> assign(:invite_url, nil)
      |> assign(:vapid_key, Veejr.Push.WebPush.vapid_public_key())
      |> assign(:push_devices, Veejr.Push.subscription_count(user))
      |> assign(:backup_form, to_form(%{}, as: :backup))
      |> allow_upload(:backup,
        accept: [".zip"],
        max_entries: 1,
        max_file_size: Veejr.Import.max_archive_bytes()
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("avatar_uploaded", _params, socket) do
    user = Accounts.get_user!(socket.assigns.current_scope.user.id)
    {:noreply, assign(socket, :current_scope, Accounts.Scope.for_user(user))}
  end

  def handle_event("validate_backup", _params, socket), do: {:noreply, socket}

  def handle_event("restore_backup", _params, socket) do
    results =
      consume_uploaded_entries(socket, :backup, fn %{path: path}, _entry ->
        result =
          with {:ok, zip_binary} <- File.read(path) do
            Veejr.Import.restore(zip_binary, socket.assigns.current_scope.user)
          end

        {:ok, result}
      end)

    case results do
      [{:ok, summary}] ->
        user = Accounts.get_user!(socket.assigns.current_scope.user.id)

        info =
          "Backup restored: #{summary.envelopes} messages and #{summary.blobs} attachments added."

        {:noreply,
         socket
         |> assign(:current_scope, Accounts.Scope.for_user(user))
         |> put_flash(:info, info)}

      [{:error, reason}] ->
        {:noreply, put_flash(socket, :error, backup_restore_error(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, "Choose a Veejr backup file to restore.")}
    end
  end

  def handle_event("open_profile", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    profile = if to_string(user.id) == id, do: user
    {:noreply, assign(socket, :selected_profile, profile)}
  end

  def handle_event("close_profile", _params, socket) do
    {:noreply, assign(socket, :selected_profile, nil)}
  end

  def handle_event("remove_avatar", _params, socket) do
    case Accounts.remove_user_avatar(socket.assigns.current_scope.user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, Accounts.Scope.for_user(user))
         |> put_flash(:info, "Profile image removed.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Profile image could not be removed.")}
    end
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("generate_invite", _params, socket) do
    token = Accounts.generate_invite(socket.assigns.current_scope.user)
    {:noreply, assign(socket, :invite_url, url(~p"/users/register?invite=#{token}"))}
  end

  def handle_event("delete_account", _params, socket) do
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.delete_user(user) do
      {:ok, _} ->
        # Session tokens are cascade-deleted, so the current session is
        # already invalid — a full redirect lands on the logged-out home page.
        {:noreply, redirect(socket, to: ~p"/")}

      {:error, :instance_admin} ->
        {:noreply, put_flash(socket, :error, "The instance administrator cannot be deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete your account — please try again.")}
    end
  end

  defp backup_upload_label([]), do: "Choose a backup"
  defp backup_upload_label([entry | _entries]), do: entry.client_name

  defp backup_upload_error(:too_large), do: "That backup is too large."
  defp backup_upload_error(:not_accepted), do: "Choose a .zip backup created by Veejr."
  defp backup_upload_error(:too_many_files), do: "Choose one backup at a time."
  defp backup_upload_error(_error), do: "That file could not be uploaded."

  defp backup_restore_error(:account_mismatch),
    do: "That backup belongs to a different account or encryption-key identity."

  defp backup_restore_error(:archive_too_large), do: "That backup is too large."
  defp backup_restore_error(:unsafe_archive), do: "That backup has an unsafe archive structure."
  defp backup_restore_error(:not_a_zip), do: "That file is not a valid zip backup."
  defp backup_restore_error(:missing_manifest), do: "That archive is not a Veejr backup."
  defp backup_restore_error(:invalid_manifest), do: "That backup manifest is invalid."

  defp backup_restore_error(:integrity_check_failed),
    do: "That backup failed its integrity check."

  defp backup_restore_error({:unsupported_version, _version}),
    do: "This Veejr version cannot restore that backup format."

  defp backup_restore_error(:ownership_conflict),
    do: "Restore stopped because archive data conflicts with another account."

  defp backup_restore_error(_reason), do: "The backup could not be restored."
end
