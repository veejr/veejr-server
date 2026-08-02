defmodule VeejrWeb.WatchLive do
  @moduledoc "Instance-local, host-controlled YouTube watch parties."

  use VeejrWeb, :live_view

  alias Veejr.Accounts.UserNotifier
  alias Veejr.WatchParties

  @impl true
  def mount(params, _session, socket) do
    party = party_for_action(socket.assigns.live_action, params)

    {voice_participant, voice_peers} =
      if connected?(socket) and party do
        WatchParties.subscribe(party.public_id)

        case WatchParties.join_voice(party.public_id, socket.assigns.current_scope.user) do
          {:ok, participant, peers} -> {participant, peers}
          {:error, _reason} -> {nil, []}
        end
      else
        {nil, []}
      end

    socket =
      socket
      |> assign(:party, party)
      |> assign(:host?, party && party.host_id == socket.assigns.current_scope.user.id)
      |> assign(:watch_form, to_form(%{"url" => ""}, as: :watch))
      |> assign(:outsider_invites_form, to_form(%{"emails" => ""}, as: :outsider_invites))
      |> assign(:voice_participant, voice_participant)
      |> assign(:voice_peers, Jason.encode!(voice_peers))
      |> assign(:ice_servers, Jason.encode!(Veejr.Calls.IceConfig.servers()))

    case {socket.assigns.live_action, party} do
      {:show, nil} ->
        {:ok,
         socket
         |> put_flash(:error, "That watch party has ended.")
         |> push_navigate(to: ~p"/watch")}

      _ ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_event("start", %{"watch" => %{"url" => url}}, socket) do
    case WatchParties.start_party(socket.assigns.current_scope.user, url) do
      {:ok, party} ->
        {:noreply, push_navigate(socket, to: ~p"/watch/#{party.public_id}")}

      {:error, :party_active} ->
        {:noreply, put_flash(socket, :error, "A watch party is already active.")}

      {:error, :invalid_youtube_url} ->
        {:noreply, put_flash(socket, :error, "Enter a valid YouTube link or video ID.")}
    end
  end

  def handle_event("watch_control", %{"playback" => playback, "position" => position}, socket) do
    if socket.assigns.host? do
      WatchParties.control(
        socket.assigns.party.public_id,
        socket.assigns.current_scope.user.id,
        playback,
        position
      )
    end

    {:noreply, socket}
  end

  def handle_event("end_party", _params, socket) do
    if socket.assigns.host? do
      WatchParties.end_party(socket.assigns.party.public_id, socket.assigns.current_scope.user.id)
    end

    {:noreply, push_navigate(socket, to: ~p"/watch")}
  end

  def handle_event(
        "invite_outsiders",
        %{"outsider_invites" => %{"emails" => emails}},
        socket
      ) do
    if socket.assigns.host? do
      host = socket.assigns.current_scope.user
      party = socket.assigns.party

      case WatchParties.create_guest_invites(party.public_id, host.id, emails) do
        {:ok, invitations} ->
          {sent, failed} =
            Enum.reduce(invitations, {0, 0}, fn invitation, {sent, failed} ->
              invite_url = url(~p"/watch/guest/#{invitation.token}")

              case UserNotifier.deliver_guest_watch_party_invitation(
                     host,
                     invitation.email,
                     invite_url
                   ) do
                {:ok, _email} ->
                  {sent + 1, failed}

                {:error, _reason} ->
                  WatchParties.revoke_guest_invite(
                    party.public_id,
                    host.id,
                    invitation.token
                  )

                  {sent, failed + 1}
              end
            end)

          {:noreply, guest_invitation_result(socket, sent, failed)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, guest_invitation_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, "Only the watch-party host can invite guests.")}
    end
  end

  def handle_event(
        "watch_voice_signal",
        %{"target" => target, "ciphertext" => ciphertext, "nonce" => nonce},
        socket
      ) do
    if socket.assigns.voice_participant do
      WatchParties.signal_voice(
        socket.assigns.party.public_id,
        socket.assigns.voice_participant.id,
        target,
        ciphertext,
        nonce
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:watch_party_control, party}, socket) do
    socket = assign(socket, :party, party)

    if socket.assigns.host? do
      {:noreply, socket}
    else
      {:noreply,
       push_event(socket, "watch:control", %{
         playback: party.playback,
         position: party.position
       })}
    end
  end

  def handle_info({:watch_party_ended, _public_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "The host ended the watch party.")
     |> push_navigate(to: ~p"/watch")}
  end

  def handle_info({:watch_voice_joined, participant}, socket) do
    if socket.assigns.voice_participant && participant.id != socket.assigns.voice_participant.id do
      {:noreply, push_event(socket, "watch:voice_joined", %{participant: participant})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:watch_voice_left, participant_id}, socket) do
    {:noreply, push_event(socket, "watch:voice_left", %{participant_id: participant_id})}
  end

  def handle_info(
        {:watch_voice_signal, target_id, sender, ciphertext, nonce},
        socket
      ) do
    if socket.assigns.voice_participant && target_id == socket.assigns.voice_participant.id do
      {:noreply,
       push_event(socket, "watch:voice_signal", %{
         sender: sender,
         ciphertext: ciphertext,
         nonce: nonce
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-5xl"
    >
      <%= if @live_action == :show do %>
        <section id="watch-party" class="space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p class="text-sm font-medium text-primary">YouTube watch party</p>
              <h1 class="text-2xl font-semibold tracking-tight">Hosted by {@party.host}</h1>
              <p class="mt-1 text-sm opacity-65">
                <%= if @host? do %>
                  Your YouTube controls direct playback for everyone.
                <% else %>
                  Only the host can play, pause, or seek.
                <% end %>
              </p>
            </div>
            <button :if={@host?} id="watch-end" phx-click="end_party" class="btn btn-error btn-sm">
              <.icon name="hero-stop" class="size-4" /> End party
            </button>
          </div>

          <div class="overflow-hidden rounded-[28px] border border-base-300 bg-black shadow-xl">
            <div
              id="youtube-watch-player"
              phx-hook="YouTubeWatch"
              phx-update="ignore"
              data-host={to_string(@host?)}
              data-video-id={@party.video_id}
              data-playback={@party.playback}
              data-position={@party.position}
              class="relative aspect-video w-full"
            >
              <iframe
                id="youtube-watch-iframe"
                data-role="player"
                src={youtube_embed_url(@party.video_id, @host?)}
                title="Shared YouTube video"
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
                allowfullscreen
                referrerpolicy="strict-origin-when-cross-origin"
                class="absolute inset-0 size-full"
              ></iframe>
              <div
                :if={!@host?}
                id="watch-youtube-guard"
                data-role="guard"
                aria-hidden="true"
                class="absolute inset-0 z-20"
              >
              </div>
              <.youtube_viewer_bar
                id="watch-youtube-help"
                label={if @host?, do: "You control this video", else: "Controlled by the host"}
              />
              <button
                :if={!@host?}
                type="button"
                data-role="unlock"
                class="absolute inset-0 z-30 flex size-full cursor-pointer items-center justify-center bg-black/35 text-white transition hover:bg-black/25"
              >
                <span class="rounded-full bg-black/75 px-5 py-3 text-sm font-semibold shadow-lg backdrop-blur">
                  <.icon name="hero-play" class="mr-1 inline size-5" /> Tap to join playback
                </span>
              </button>
              <.youtube_playback_assist id="watch-youtube-assist" />
            </div>
          </div>

          <div class="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-base-300 bg-base-100 p-4">
            <p class="text-sm opacity-65">
              veejr relays synchronization directions only; video streams directly from YouTube.
            </p>
            <button
              id="watch-fullscreen"
              type="button"
              data-watch-fullscreen
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-arrows-pointing-out" class="size-4" /> Full screen
            </button>
          </div>

          <section
            :if={@host?}
            id="watch-outsider-invites"
            class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm"
          >
            <div class="border-b border-base-300 bg-primary/5 px-5 py-4">
              <div class="flex items-start gap-3">
                <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary">
                  <.icon name="hero-envelope" class="size-5" />
                </span>
                <div>
                  <h2 class="font-semibold">Invite outsiders</h2>
                  <p class="mt-1 text-sm leading-6 opacity-65">
                    Email private guest links to people who do not have Veejr accounts.
                  </p>
                </div>
              </div>
            </div>

            <.form
              for={@outsider_invites_form}
              id="watch-outsider-invite-form"
              phx-submit="invite_outsiders"
              class="space-y-4 p-5"
            >
              <.input
                field={@outsider_invites_form[:emails]}
                type="textarea"
                label="Email addresses"
                placeholder="alex@example.com, sam@example.org"
                rows="3"
                spellcheck="false"
                required
              />
              <p class="text-xs leading-5 opacity-60">
                Separate up to 25 addresses with commas. Each person gets a different
                capability link that expires when this party ends. Guest links include
                synchronized playback, but encrypted party voice requires a Veejr identity.
              </p>
              <button
                id="send-watch-outsider-invites"
                type="submit"
                phx-disable-with="Sending invitations…"
                class="btn btn-primary btn-sm rounded-xl"
              >
                <.icon name="hero-paper-airplane" class="size-4" /> Send invitations
              </button>
            </.form>
          </section>

          <div
            id="watch-voice"
            phx-hook="WatchVoice"
            phx-update="ignore"
            data-party-id={@party.public_id}
            data-participant-id={@voice_participant && @voice_participant.id}
            data-user-id={@current_scope.user.id}
            data-peers={@voice_peers}
            data-ice-servers={@ice_servers}
            class="flex flex-wrap items-center gap-4 rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
          >
            <div class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
              <.icon name="hero-speaker-wave" class="size-5" />
            </div>
            <div class="min-w-44 flex-1">
              <p class="font-semibold">Party voice</p>
              <p data-role="voice-status" class="text-sm opacity-65">
                Microphone off · connecting listeners…
              </p>
            </div>
            <button
              id="watch-microphone"
              type="button"
              data-role="toggle-microphone"
              aria-pressed="false"
              class="btn btn-primary btn-sm"
            >
              <span data-role="mic-on-icon"><.icon name="hero-microphone" class="size-4" /></span>
              <span data-role="mic-off-icon" class="hidden">
                <.icon name="hero-microphone-slash" class="size-4" />
              </span>
              <span data-role="mic-label">Turn microphone on</span>
            </button>
            <div data-role="remote-audio" aria-live="polite"></div>
          </div>
        </section>
      <% else %>
        <section id="watch-lobby" class="mx-auto max-w-2xl space-y-5">
          <div class="rounded-[30px] border border-base-300 bg-base-100 p-6 shadow-sm sm:p-8">
            <div class="mb-6 flex size-12 items-center justify-center rounded-2xl bg-error/10 text-error">
              <.icon name="hero-play" class="size-7" />
            </div>
            <h1 class="text-3xl font-semibold tracking-tight">Watch YouTube together</h1>
            <p class="mt-2 leading-relaxed opacity-70">
              Start one shared video for everyone currently online on this veejr instance. People choose whether to join, and only you control playback.
            </p>

            <%= if @party do %>
              <div
                id="active-watch-party"
                class="mt-6 rounded-2xl border border-primary/25 bg-primary/5 p-5"
              >
                <p class="font-semibold">{@party.host} is hosting now</p>
                <p class="mt-1 text-sm opacity-65">
                  Join the synchronized video already in progress.
                </p>
                <.link navigate={~p"/watch/#{@party.public_id}"} class="btn btn-primary mt-4">
                  <.icon name="hero-play" class="size-4" />
                  {if @party.host_id == @current_scope.user.id,
                    do: "Resume hosting",
                    else: "Join party"}
                </.link>
              </div>
            <% else %>
              <.form for={@watch_form} id="watch-start-form" phx-submit="start" class="mt-6 space-y-4">
                <.input
                  field={@watch_form[:url]}
                  type="text"
                  label="YouTube link or video ID"
                  placeholder="https://www.youtube.com/watch?v=..."
                  autocomplete="off"
                  required
                />
                <button id="watch-start" type="submit" class="btn btn-primary w-full sm:w-auto">
                  <.icon name="hero-user-group" class="size-4" /> Start watch party
                </button>
              </.form>
            <% end %>
          </div>
        </section>
      <% end %>
    </Layouts.app>
    """
  end

  defp party_for_action(:new, _params), do: WatchParties.active_party()

  defp party_for_action(:show, %{"public_id" => public_id}) do
    case WatchParties.active_party() do
      %{public_id: ^public_id} = party -> party
      _ -> nil
    end
  end

  # Mirrors `youtubeEmbedUrl` in `assets/js/veejr/youtube_embed.js`, which
  # rebuilds this same URL against `youtube.com` when a viewer reaches for the
  # signed-in escape hatch. Keep the two in step or the player changes
  # character the moment someone uses it.
  defp youtube_embed_url(video_id, host?) do
    query =
      URI.encode_query(%{
        "enablejsapi" => "1",
        "playsinline" => "1",
        "rel" => "0",
        "controls" => if(host?, do: "1", else: "0"),
        "disablekb" => if(host?, do: "0", else: "1"),
        "fs" => "1",
        "iv_load_policy" => "3"
      })

    "https://www.youtube-nocookie.com/embed/#{video_id}?#{query}"
  end

  defp guest_invitation_result(socket, sent, 0) do
    socket
    |> assign(:outsider_invites_form, to_form(%{"emails" => ""}, as: :outsider_invites))
    |> put_flash(
      :info,
      "#{sent} outsider invitation#{if sent == 1, do: "", else: "s"} sent."
    )
  end

  defp guest_invitation_result(socket, sent, failed) do
    put_flash(
      socket,
      :error,
      "#{sent} invitation#{if sent == 1, do: "", else: "s"} sent; " <>
        "#{failed} could not be delivered."
    )
  end

  defp guest_invitation_error(:no_guest_emails),
    do: "Enter at least one email address."

  defp guest_invitation_error(:too_many_guest_emails),
    do: "Invite no more than 25 outsiders at a time."

  defp guest_invitation_error({:invalid_guest_email, email}),
    do: "#{email} is not a valid email address."

  defp guest_invitation_error(:not_host),
    do: "Only the watch-party host can invite guests."

  defp guest_invitation_error(_reason),
    do: "The outsider invitations could not be created."
end
