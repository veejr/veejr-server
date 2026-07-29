defmodule VeejrWeb.InvitationLive.New do
  use VeejrWeb, :live_view

  alias Veejr.Accounts
  alias Veejr.Social.Address

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      container_class="mx-auto max-w-2xl space-y-6"
    >
      <.header>
        Invite someone
        <:subtitle>
          Ask them to scan this code. The invitation can be used once and expires in {@invitation_lifetime_days} days.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/guest-conferences/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-video-camera" class="size-4" /> Guest call
          </.link>
          <.link navigate={~p"/contacts"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Contacts
          </.link>
        </:actions>
      </.header>

      <p :if={not @invitation_available} class="border-y border-base-300 py-5 text-sm">
        Invitations are currently closed by the instance administrator.
      </p>

      <section
        :if={@invitation_available}
        class="grid items-center gap-6 rounded-lg border border-base-300 bg-base-100 p-5 sm:grid-cols-[minmax(0,1fr)_16rem]"
      >
        <div>
          <p class="text-sm font-semibold uppercase opacity-60">Invitation from</p>
          <p class="mt-1 text-xl font-semibold">
            {@current_scope.user.display_name || Address.handle(@current_scope.user)}
          </p>
          <p class="text-sm opacity-70">{Address.handle(@current_scope.user)}</p>

          <p class="mt-5 text-sm font-semibold uppercase opacity-60">Joining</p>
          <p class="mt-1 font-medium">{Veejr.instance_name()}</p>

          <label for="invite-url" class="mt-5 block text-sm font-medium">Invitation link</label>
          <input
            id="invite-url"
            type="text"
            value={@invite_url}
            readonly
            class="input mt-1 w-full font-mono text-xs"
          />

          <div
            id="invite-actions"
            phx-hook=".InviteActions"
            phx-update="ignore"
            data-url={@invite_url}
            class="mt-3 flex flex-wrap items-center gap-2"
          >
            <button type="button" data-role="copy-invite" class="btn btn-primary btn-sm">
              <.icon name="hero-clipboard-document" class="size-4" /> Copy link
            </button>
            <button type="button" data-role="share-invite" class="btn btn-outline btn-sm">
              <.icon name="hero-share" class="size-4" /> Share invite
            </button>
            <span data-role="invite-action-status" aria-live="polite" class="text-xs opacity-70"></span>
          </div>
        </div>

        <div class="mx-auto aspect-square w-full max-w-64 rounded-lg border border-base-300 bg-white p-3">
          <img
            src={"data:image/svg+xml;base64,#{@qr_code}"}
            alt="QR code for this invitation"
            class="size-full"
          />
        </div>
      </section>

      <div :if={@invitation_available} class="flex justify-end">
        <button phx-click="new_invitation" class="btn btn-outline btn-sm">
          <.icon name="hero-arrow-path" class="size-4" /> Create another code
        </button>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".InviteActions">
        export default {
          mounted() {
            this.copyButton = this.el.querySelector("[data-role=copy-invite]")
            this.shareButton = this.el.querySelector("[data-role=share-invite]")
            this.status = this.el.querySelector("[data-role=invite-action-status]")

            this.copyButton.addEventListener("click", () => this.copyInvite())
            this.shareButton.addEventListener("click", () => this.shareInvite())
          },

          updated() {
            this.status.textContent = ""
          },

          async copyInvite() {
            try {
              await this.copyText(this.el.dataset.url)
              this.status.textContent = "Invitation link copied."
            } catch (_error) {
              this.status.textContent = "Could not copy the link."
            }
          },

          async shareInvite() {
            if (navigator.share) {
              try {
                await navigator.share({
                  title: "Join me on veejr",
                  text: "Use this invitation to join me on veejr.",
                  url: this.el.dataset.url
                })
                this.status.textContent = "Invitation shared."
              } catch (error) {
                if (error.name !== "AbortError") this.status.textContent = "Could not share the invitation."
              }
            } else {
              await this.copyInvite()
            }
          },

          async copyText(value) {
            if (navigator.clipboard?.writeText) {
              return navigator.clipboard.writeText(value)
            }

            const input = document.querySelector("#invite-url")
            input.focus()
            input.select()

            if (!document.execCommand("copy")) throw new Error("copy failed")
          }
        }
      </script>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Invite someone",
       invitation_lifetime_days: div(Veejr.InstanceSettings.invitation_lifetime_hours(), 24)
     )
     |> assign_invitation()}
  end

  @impl true
  def handle_event("new_invitation", _params, socket) do
    # Authenticated, but each call mints a capability token; budget it so one
    # account cannot generate invitations without bound.
    case Veejr.RateLimiter.check(:invitation, socket.assigns.client_ip) do
      :ok ->
        {:noreply, assign_invitation(socket)}

      {:error, retry_after} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Too many invitations created. Try again in #{retry_after} seconds."
         )}
    end
  end

  defp assign_invitation(socket) do
    case Accounts.create_invitation(socket.assigns.current_scope.user) do
      {:ok, _invitation, token} ->
        invite_url = url(~p"/users/register?invite=#{token}")

        {:ok, qr_code} =
          invite_url
          |> QRCode.create(:medium)
          |> QRCode.render(:svg)
          |> QRCode.to_base64()

        assign(socket,
          invitation_available: true,
          invite_url: invite_url,
          qr_code: qr_code
        )

      {:error, :invitations_closed} ->
        assign(socket, invitation_available: false, invite_url: nil, qr_code: nil)
    end
  end
end
