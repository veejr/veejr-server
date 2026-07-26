defmodule VeejrWeb.GuestWatchLive do
  @moduledoc "Capability-authorized synchronized playback for a watch-party outsider."

  use VeejrWeb, :live_view

  alias Veejr.WatchParties

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    party = WatchParties.guest_party(token)

    if connected?(socket) and party, do: WatchParties.subscribe(party.public_id)

    {:ok,
     assign(socket,
       page_title: "Guest watch party",
       party: party
     )}
  end

  @impl true
  def handle_info({:watch_party_control, party}, socket) do
    {:noreply,
     socket
     |> assign(:party, party)
     |> push_event("watch:control", %{
       playback: party.playback,
       position: party.position
     })}
  end

  def handle_info({:watch_party_ended, _public_id}, socket) do
    {:noreply, assign(socket, :party, nil)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} container_class="mx-auto max-w-5xl">
      <section :if={@party} id="guest-watch-party" class="space-y-4">
        <div class="rounded-3xl border border-primary/20 bg-primary/5 px-5 py-5 sm:px-7">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-primary">
            Private guest watch party
          </p>
          <h1 class="mt-2 text-2xl font-semibold tracking-tight">
            {@party.host} invited you to watch
          </h1>
          <p class="mt-2 max-w-2xl text-sm leading-6 opacity-70">
            No Veejr account is required. The host controls playback; tap the video once
            to allow synchronized playback and audio in this browser.
          </p>
        </div>

        <div class="overflow-hidden rounded-[28px] border border-base-300 bg-black shadow-xl">
          <div
            id="guest-youtube-watch-player"
            phx-hook="YouTubeWatch"
            phx-update="ignore"
            data-host="false"
            data-playback={@party.playback}
            data-position={@party.position}
            class="relative aspect-video w-full"
          >
            <iframe
              id="guest-youtube-watch-iframe"
              data-role="player"
              src={youtube_embed_url(@party.video_id)}
              title="Shared YouTube video"
              allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
              allowfullscreen
              referrerpolicy="strict-origin-when-cross-origin"
              class="pointer-events-none absolute inset-0 size-full"
            ></iframe>
            <button
              type="button"
              data-role="unlock"
              class="absolute inset-0 flex size-full cursor-pointer items-center justify-center bg-black/35 text-white transition hover:bg-black/25"
            >
              <span class="rounded-full bg-black/75 px-5 py-3 text-sm font-semibold shadow-lg backdrop-blur">
                <.icon name="hero-play" class="mr-1 inline size-5" /> Tap to join playback
              </span>
            </button>
          </div>
        </div>

        <div class="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-base-300 bg-base-100 p-4">
          <p class="text-sm opacity-65">
            Video streams directly from YouTube. This guest link exposes no Veejr
            contacts, messages, or account data.
          </p>
          <button
            id="guest-watch-fullscreen"
            type="button"
            data-watch-fullscreen
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-arrows-pointing-out" class="size-4" /> Full screen
          </button>
        </div>
      </section>

      <section
        :if={!@party}
        id="guest-watch-unavailable"
        class="mx-auto max-w-lg rounded-3xl border border-base-300 bg-base-100 p-8 text-center shadow-sm"
      >
        <span class="mx-auto grid size-12 place-items-center rounded-2xl bg-base-200">
          <.icon name="hero-video-camera-slash" class="size-6 opacity-60" />
        </span>
        <h1 class="mt-4 text-xl font-semibold">Watch party unavailable</h1>
        <p class="mt-2 text-sm leading-6 opacity-65">
          This invitation is invalid, the host ended the party, or the service restarted.
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp youtube_embed_url(video_id) do
    query =
      URI.encode_query(%{
        "enablejsapi" => "1",
        "playsinline" => "1",
        "rel" => "0",
        "controls" => "0"
      })

    "https://www.youtube-nocookie.com/embed/#{video_id}?#{query}"
  end
end
