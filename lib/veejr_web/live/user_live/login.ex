defmodule VeejrWeb.UserLive.Login do
  use VeejrWeb, :live_view

  alias Veejr.Accounts
  alias VeejrWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Log in</p>
            <:subtitle>
              <%= if @current_scope do %>
                You need to reauthenticate to perform sensitive actions on your account.
              <% else %>
                Don't have an account? <.link
                  navigate={~p"/users/register"}
                  class="font-semibold text-brand hover:underline"
                  phx-no-format
                >Sign up</.link> for an account now.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
            </p>
          </div>
        </div>

        <.form
          for={@form}
          id="login_form_magic"
          action={login_path(@return_to)}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:identifier]}
            id="login_form_magic_identifier"
            type="text"
            label="Username or email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full">
            Email me a one-time link <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div class="divider">or</div>

        <.form
          for={@form}
          id="login_form_password"
          action={login_path(@return_to)}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:identifier]}
            id="login_form_password_identifier"
            type="text"
            label="Username or email"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
            Log in and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-primary btn-soft w-full mt-2">
            Log in only this time
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    identifier =
      Phoenix.Flash.get(socket.assigns.flash, :identifier) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"identifier" => identifier}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       return_to: UserAuth.local_return_to(params["return_to"])
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"identifier" => identifier}}, socket) do
    return_to = socket.assigns.return_to

    # This runs over the LiveView socket rather than a controller, so the
    # router's :limit_magic_link pipeline never sees it. Budget it here on the
    # same bucket so both entry points share one allowance per client.
    case Veejr.RateLimiter.check(:magic_link, socket.assigns.client_ip) do
      :ok ->
        if user = Accounts.get_user_by_login_identifier(identifier) do
          Accounts.deliver_login_instructions(
            user,
            &magic_login_url(&1, return_to)
          )
        end

        info =
          "If your username or email is in our system, you will receive instructions for logging in shortly."

        {:noreply,
         socket
         |> put_flash(:info, info)
         |> push_navigate(to: login_path(return_to))}

      {:error, retry_after} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Too many login requests. Try again in #{retry_after} seconds."
         )}
    end
  end

  defp login_path(nil), do: ~p"/users/log-in"
  defp login_path(return_to), do: ~p"/users/log-in?#{[return_to: return_to]}"

  defp magic_login_url(token, nil), do: url(~p"/users/log-in/#{token}")

  defp magic_login_url(token, return_to),
    do: url(~p"/users/log-in/#{token}?#{[return_to: return_to]}")

  defp local_mail_adapter? do
    Application.get_env(:veejr, Veejr.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
