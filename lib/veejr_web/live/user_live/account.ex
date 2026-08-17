defmodule VeejrWeb.UserLive.Account do
  use VeejrWeb, :live_view

  alias Veejr.{Accounts, Push}
  alias Veejr.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      container_class="mx-auto max-w-2xl space-y-8"
    >
      <section class="space-y-2">
        <p class="text-sm font-medium uppercase tracking-[0.2em] text-primary">Account</p>
        <.header>
          {@current_scope.user.username}
          <:subtitle>Manage your account, security, and device preferences.</:subtitle>
        </.header>
      </section>

      <section
        id="experience-mode"
        class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm"
      >
        <div class="flex items-start gap-3">
          <span class="flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
            <.icon name="hero-adjustments-horizontal" class="size-5" />
          </span>
          <div>
            <h2 class="font-semibold">Experience mode</h2>
            <p class="mt-1 text-sm leading-6 text-base-content/65">
              Choose once. Simple keeps people and conversations in focus; Full puts every tool, view, and template within easy reach.
            </p>
          </div>
        </div>
        <div class="mt-4 grid gap-3 sm:grid-cols-2" role="radiogroup" aria-label="Experience mode">
          <button
            id="experience-mode-simple"
            type="button"
            role="radio"
            aria-checked={to_string(@current_scope.user.page_layout == "simple")}
            phx-click="set_experience_mode"
            phx-value-mode="simple"
            class={[
              "rounded-2xl border p-4 text-left transition hover:-translate-y-0.5 hover:shadow-md",
              @current_scope.user.page_layout == "simple" && "border-primary bg-primary/10",
              @current_scope.user.page_layout != "simple" && "border-base-300 bg-base-200/40"
            ]}
          >
            <span class="flex items-center gap-2 font-semibold"><.icon
              name="hero-user-group"
              class="size-5"
            /> Simple</span>
            <span class="mt-1 block text-sm text-base-content/60">Contacts, messages, and only the essentials.</span>
          </button>
          <button
            id="experience-mode-full"
            type="button"
            role="radio"
            aria-checked={to_string(@current_scope.user.page_layout == "full")}
            phx-click="set_experience_mode"
            phx-value-mode="full"
            class={[
              "rounded-2xl border p-4 text-left transition hover:-translate-y-0.5 hover:shadow-md",
              @current_scope.user.page_layout == "full" && "border-primary bg-primary/10",
              @current_scope.user.page_layout != "full" && "border-base-300 bg-base-200/40"
            ]}
          >
            <span class="flex items-center gap-2 font-semibold"><.icon
              name="hero-squares-2x2"
              class="size-5"
            /> Full</span>
            <span class="mt-1 block text-sm text-base-content/60">All views, themes, notes, groups, calls, and add-ons.</span>
          </button>
        </div>
      </section>

      <section
        id="account-status"
        phx-hook="AccountStatus"
        data-user-id={@current_scope.user.id}
        data-has-identity={not is_nil(@current_scope.user.public_key)}
        class="rounded-2xl border border-base-300/70 bg-base-200/40 p-5"
      >
        <div class="mb-4 flex items-center gap-3">
          <span class="flex size-9 items-center justify-center rounded-full bg-primary/10 text-primary">
            <.icon name="hero-identification" class="size-5" />
          </span>
          <div>
            <h2 class="font-semibold">Account identity</h2>
            <p class="text-sm text-base-content/60">Profile and device status</p>
          </div>
        </div>

        <dl class="grid gap-3 text-sm sm:grid-cols-2">
          <div id="account-nickname" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">Nickname</dt>
            <dd class="mt-1 font-medium">{@current_scope.user.display_name || "Not set"}</dd>
          </div>
          <div id="account-username" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">Username</dt>
            <dd class="mt-1 font-medium">@{@current_scope.user.username}</dd>
          </div>
          <div id="account-role" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">Instance role</dt>
            <dd class="mt-1">
              <span class={[
                "badge badge-sm",
                if(@instance_admin, do: "badge-primary", else: "badge-neutral")
              ]}>
                {if @instance_admin, do: "Instance administrator", else: "Member"}
              </span>
            </dd>
          </div>
          <div id="account-identity-status" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">
              Identity (this browser)
            </dt>
            <dd class="mt-1">
              <span
                data-role="identity-status"
                class="badge badge-sm badge-neutral"
                aria-live="polite"
              >
                Checking…
              </span>
            </dd>
          </div>
          <div id="account-fcm-status" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">FCM notifications</dt>
            <dd class="mt-1">
              <span class={[
                "badge badge-sm",
                if(@fcm_device_count > 0, do: "badge-success", else: "badge-warning")
              ]}>
                {if @fcm_device_count > 0, do: "Registered", else: "Not registered"}
              </span>
              <span :if={@fcm_device_count > 0} class="ml-1 text-xs text-base-content/60">
                ({@fcm_device_count} device{if @fcm_device_count != 1, do: "s"})
              </span>
            </dd>
          </div>
        </dl>
      </section>

      <section class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3" aria-label="Account settings">
        <.link
          :if={@instance_admin}
          navigate={~p"/admin"}
          id="account-admin-link"
          class="group rounded-2xl border border-primary/40 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-primary hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <div class="flex items-start justify-between gap-4">
            <span class="flex size-11 items-center justify-center rounded-xl bg-primary/10 text-primary">
              <.icon name="hero-command-line" class="size-6" />
            </span>
            <.icon
              name="hero-arrow-up-right"
              class="size-5 text-base-content/40 transition group-hover:text-primary"
            />
          </div>
          <h2 class="mt-5 text-lg font-semibold">Instance administration</h2>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Review instance health, usage, queues, and runtime information.
          </p>
        </.link>

        <.link
          navigate={~p"/users/settings"}
          id="account-settings-link"
          class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/50 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <div class="flex items-start justify-between gap-4">
            <span class="flex size-11 items-center justify-center rounded-xl bg-primary/10 text-primary">
              <.icon name="hero-cog-6-tooth" class="size-6" />
            </span>
            <.icon
              name="hero-arrow-up-right"
              class="size-5 text-base-content/40 transition group-hover:text-primary"
            />
          </div>
          <h2 class="mt-5 text-lg font-semibold">Settings</h2>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Update your email, password, notifications, app installation, and account data.
          </p>
        </.link>

        <.link
          navigate={~p"/keys"}
          id="account-keys-link"
          class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/50 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <div class="flex items-start justify-between gap-4">
            <span class="flex size-11 items-center justify-center rounded-xl bg-secondary/10 text-secondary">
              <.icon name="hero-key" class="size-6" />
            </span>
            <.icon
              name="hero-arrow-up-right"
              class="size-5 text-base-content/40 transition group-hover:text-primary"
            />
          </div>
          <div class="mt-5 flex items-center gap-2">
            <h2 class="text-lg font-semibold">Encryption keys</h2>
            <span class={[
              "badge badge-sm",
              if(@current_scope.user.public_key, do: "badge-success", else: "badge-warning")
            ]}>
              {if @current_scope.user.public_key, do: "Configured", else: "Set up"}
            </span>
          </div>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Unlock, change, rotate, or reset the keys that protect your conversations.
          </p>
        </.link>

        <.link
          navigate={~p"/account/archives"}
          id="account-archives-link"
          class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/50 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <div class="flex items-start justify-between gap-4">
            <span class="flex size-11 items-center justify-center rounded-xl bg-base-200 text-base-content/70">
              <.icon name="hero-archive-box" class="size-6" />
            </span>
            <.icon
              name="hero-arrow-up-right"
              class="size-5 text-base-content/40 transition group-hover:text-primary"
            />
          </div>
          <h2 class="mt-5 text-lg font-semibold">Archived conversations</h2>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Review conversations you have tucked away and bring them back when needed.
          </p>
        </.link>
      </section>

      <section
        id="account-device-sessions"
        class="rounded-2xl border border-base-300/70 bg-base-200/40 p-5"
      >
        <div class="mb-4 flex items-center gap-3">
          <span class="flex size-9 items-center justify-center rounded-full bg-primary/10 text-primary">
            <.icon name="hero-device-phone-mobile" class="size-5" />
          </span>
          <div>
            <h2 class="font-semibold">Signed-in devices</h2>
            <p class="text-sm text-base-content/60">
              Review browser and Android sessions and revoke devices you no longer use.
            </p>
          </div>
        </div>

        <ul id="device-session-list" class="space-y-2">
          <li
            :for={session <- @device_sessions}
            id={"device-session-#{session.kind}-#{session.id}"}
            class="flex flex-wrap items-center gap-3 rounded-xl bg-base-100/80 px-3 py-3"
          >
            <span class="flex size-9 items-center justify-center rounded-full bg-base-200">
              <.icon
                name={
                  if(session.kind == "android",
                    do: "hero-device-phone-mobile",
                    else: "hero-computer-desktop"
                  )
                }
                class="size-4"
              />
            </span>
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium">
                {session.name}
                <span :if={session.current} class="badge badge-primary badge-xs ml-1">Current</span>
              </p>
              <p class="text-xs opacity-60">
                {session.platform}{if(session.app_version, do: " · #{session.app_version}")} · active {Calendar.strftime(
                  session.last_used_at,
                  "%b %d, %Y · %H:%M UTC"
                )}
              </p>
            </div>
            <button
              :if={!session.current}
              id={"revoke-device-session-#{session.kind}-#{session.id}"}
              type="button"
              phx-click="revoke_device_session"
              phx-value-kind={session.kind}
              phx-value-id={session.id}
              data-confirm="Sign this device out?"
              class="btn btn-ghost btn-sm text-error"
            >
              Revoke
            </button>
          </li>
        </ul>
      </section>

      <section class="rounded-2xl border border-base-300/70 bg-base-200/40 p-5">
        <div class="flex items-center gap-3">
          <span class="flex size-9 items-center justify-center rounded-full bg-base-100 text-base-content/70">
            <.icon name="hero-at-symbol" class="size-5" />
          </span>
          <div>
            <p class="text-xs font-medium uppercase tracking-wide text-base-content/60">
              Signed in as
            </p>
            <p class="font-medium">{@current_scope.user.email}</p>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     assign(socket,
       page_title: "Account",
       instance_admin: Veejr.Accounts.instance_admin?(user),
       fcm_device_count: Push.android_registration_count(user),
       device_sessions:
         Veejr.Accounts.list_device_sessions(
           socket.assigns.current_scope,
           socket.assigns.current_session_id
         )
     )}
  end

  @impl true
  def handle_event("set_experience_mode", %{"mode" => mode}, socket)
      when mode in ["simple", "full"] do
    case Accounts.set_page_layout(socket.assigns.current_scope.user, mode) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, Scope.for_user(user))
         |> put_flash(
           :info,
           "#{if(mode == "simple", do: "Simple", else: "Full")} mode is now active."
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save that mode.")}
    end
  end

  def handle_event("set_experience_mode", _params, socket) do
    {:noreply, put_flash(socket, :error, "That mode is not available.")}
  end

  @impl true
  def handle_event("revoke_device_session", %{"kind" => kind, "id" => id}, socket) do
    case Veejr.Accounts.revoke_device_session(
           socket.assigns.current_scope,
           kind,
           id,
           socket.assigns.current_session_id
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           :device_sessions,
           Veejr.Accounts.list_device_sessions(
             socket.assigns.current_scope,
             socket.assigns.current_session_id
           )
         )
         |> put_flash(:info, "Device signed out.")}

      {:error, :current_session} ->
        {:noreply, put_flash(socket, :error, "Use Log out to end this browser session.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That device session was not found.")}
    end
  end
end
