defmodule VeejrWeb.CallLive do
  @moduledoc """
  One active 1:1 call. Both participants sit on this page for the duration;
  leaving it hangs up. The page carries only sealed signaling — media flows
  peer-to-peer via the `CallSession` hook, and SDP/ICE payloads are
  encrypted browser-side between the participants' pinned identity keys.
  """

  use VeejrWeb, :live_view

  alias Veejr.{Calls, Messaging, Social}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@layout_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-5xl"
    >
      <div
        id="call-session"
        phx-hook="CallSession"
        phx-update="ignore"
        data-call-id={@call.public_id}
        data-call-state={@call.state}
        data-role={@role}
        data-user-id={@actor.id}
        data-local-id={@local_id}
        data-peers={Jason.encode!(@peers)}
        data-my-key={@actor.public_key}
        data-enc-secret-key={@actor.enc_secret_key}
        data-key-salt={@actor.key_salt}
        data-key-nonce={@actor.key_nonce}
        data-is-guest={to_string(@is_guest)}
        data-ice-servers={@ice_servers}
        data-youtube-active="false"
        class="overflow-hidden rounded-[32px] border border-base-300 bg-base-200 shadow-sm"
      >
        <div
          data-role="call-header"
          class="flex items-center justify-between gap-3 border-b border-base-300 bg-base-100 px-5 py-4"
        >
          <div class="min-w-0">
            <%!-- The hook rewrites this from the roster as people join or leave. --%>
            <h1 data-role="call-title" class="text-xl font-semibold tracking-tight">
              📞 {@peer.display_name || Veejr.Social.Address.handle(@peer)}
            </h1>
            <div class="mt-0.5 flex flex-wrap items-center gap-2">
              <p data-role="call-status" class="text-sm opacity-70">
                {if @role == "caller", do: "Ringing…", else: "Connecting…"}
              </p>
              <span
                id="call-duration"
                data-role="call-duration"
                class="hidden rounded-full bg-base-200 px-2 py-0.5 font-mono text-xs tabular-nums opacity-70"
              >
                00:00
              </span>
              <span
                id="call-quality"
                data-role="call-quality"
                class="hidden rounded-full border px-2 py-0.5 text-xs font-medium"
              >
                Measuring…
              </span>
              <span
                id="call-share-status"
                data-role="remote-share-status"
                class="hidden items-center gap-1 rounded-full border border-primary/30 bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary"
              >
                <.icon name="hero-computer-desktop" class="size-3.5" /> Screen shared
              </span>
              <span
                id="call-peer-muted"
                data-role="peer-muted"
                class="hidden items-center gap-1 rounded-full border border-warning/30 bg-warning/10 px-2 py-0.5 text-xs font-medium text-warning"
              >
                <.icon name="hero-microphone" class="size-3.5" /> Peer muted
              </span>
              <span
                id="call-peer-camera-off"
                data-role="peer-camera-off"
                class="hidden items-center gap-1 rounded-full border border-base-300 bg-base-200 px-2 py-0.5 text-xs font-medium opacity-70"
              >
                <.icon name="hero-video-camera-slash" class="size-3.5" /> Peer camera off
              </span>
            </div>
          </div>
          <button
            id="hang-up"
            phx-click="hangup"
            data-call-exit
            class="btn btn-error btn-sm"
          >
            <.icon name="hero-phone-x-mark" class="size-4" />
            <span data-role="hangup-label">
              {if @role == "caller" and @call.state == "ringing",
                do: "Cancel invitation",
                else: "End call"}
            </span>
          </button>
        </div>

        <div id="call-stage" data-role="call-stage" class="relative min-h-[60vh] bg-black">
          <%!--
          One tile per other participant, built by the hook. This video is the
          first tile's: it stays server-rendered so picture-in-picture, the
          pop-out, and speaker selection have a stable element to hold.
          --%>
          <div
            id="call-remote-tiles"
            data-role="remote-tiles"
            class="grid h-[60vh] w-full grid-cols-1 bg-black"
          >
            <video
              id="call-remote-video"
              data-role="remote-video"
              autoplay
              playsinline
              title="Double-click for fullscreen"
              class="size-full object-contain"
            ></video>
          </div>
          <video
            data-role="local-video"
            autoplay
            playsinline
            muted
            class="absolute bottom-4 right-4 h-32 w-44 rounded-lg border border-base-300 bg-base-300 object-cover shadow-lg"
          ></video>
          <p
            data-role="media-error"
            class="absolute inset-x-4 top-4 z-30 mx-auto hidden w-fit max-w-xl rounded-2xl bg-error/95 px-4 py-2 text-center text-sm text-error-content shadow-lg"
          >
          </p>

          <div
            id="call-key-unlock"
            data-role="call-key-unlock"
            class="absolute inset-0 z-50 hidden items-center justify-center overflow-y-auto bg-base-300/95 p-4 backdrop-blur-sm"
          >
            <div class="my-auto w-full max-w-md rounded-3xl border border-base-300 bg-base-100 p-6 text-base-content shadow-2xl sm:p-8">
              <div class="mx-auto flex size-12 items-center justify-center rounded-2xl bg-primary/10 text-primary">
                <.icon name="hero-lock-closed" class="size-6" />
              </div>
              <h2 class="mt-4 text-center text-2xl font-semibold tracking-tight">Unlock this call</h2>
              <p class="mt-2 text-center text-sm leading-relaxed opacity-65">
                Enter your encryption passphrase to connect securely. It stays on this device.
              </p>
              <%!-- A password field outside a form is invisible to password
              managers, but a submitting one here would be worse: the passphrase
              must never leave the device, and a default GET would put it in the
              URL. `method="dialog"` outside a <dialog> does nothing on submit,
              so the hook's handler is the only path and a JS failure navigates
              nowhere. --%>
              <form method="dialog" data-role="call-unlock-form">
                <div class="mt-5 [&_.fieldset]:mb-0">
                  <.input
                    id="call-passphrase"
                    name="call_passphrase"
                    type="password"
                    value=""
                    data-role="call-passphrase"
                    label="Encryption passphrase"
                    autocomplete="current-password"
                  />
                </div>
                <p
                  data-role="call-unlock-error"
                  role="alert"
                  class="mt-2 hidden text-sm text-error"
                >
                </p>
                <div class="mt-5 grid gap-2 sm:grid-cols-2">
                  <button
                    id="call-unlock-submit"
                    type="submit"
                    data-role="unlock-call"
                    class="btn btn-primary"
                  >
                    Unlock and continue
                  </button>
                  <button
                    id="call-unlock-cancel"
                    type="button"
                    phx-click="hangup"
                    data-call-exit
                    class="btn btn-ghost"
                  >
                    Cancel call
                  </button>
                </div>
              </form>
            </div>
          </div>

          <div
            :if={@role == "caller" and @allow_reinvite}
            id="call-reinvite"
            data-role="call-reinvite"
            class="absolute inset-0 z-50 hidden items-center justify-center overflow-y-auto bg-base-300/95 p-4 backdrop-blur-sm"
          >
            <div class="my-auto w-full max-w-md rounded-3xl border border-base-300 bg-base-100 p-6 text-center text-base-content shadow-2xl sm:p-8">
              <div class="mx-auto flex size-12 items-center justify-center rounded-2xl bg-warning/10 text-warning">
                <.icon name="hero-signal-slash" class="size-6" />
              </div>
              <h2 class="mt-4 text-2xl font-semibold tracking-tight">Connection lost</h2>
              <p class="mt-2 text-sm leading-relaxed opacity-65">
                {@peer.display_name || Veejr.Social.Address.handle(@peer)} did not reconnect automatically. You can send a fresh secure invitation.
              </p>
              <div class="mt-5 grid gap-2 sm:grid-cols-2">
                <button
                  id="call-reinvite-submit"
                  type="button"
                  phx-click="reinvite"
                  class="btn btn-primary"
                >
                  <.icon name="hero-phone-arrow-up-right" class="size-4" /> Re-invite
                </button>
                <.link navigate={@return_to} class="btn btn-ghost">Return to messages</.link>
              </div>
            </div>
          </div>

          <section
            data-role="call-youtube-stage"
            class="absolute inset-0 z-10 hidden bg-black"
            aria-label="Shared YouTube video"
          >
            <div data-role="call-youtube-player" class="absolute inset-0"></div>
            <div class="pointer-events-none absolute inset-x-3 top-3 z-30 flex items-center justify-between gap-2 sm:inset-x-4 sm:top-4">
              <span
                data-role="youtube-controller-label"
                class="rounded-full bg-black/75 px-3 py-1.5 text-xs font-semibold text-white shadow-lg backdrop-blur"
              >
                YouTube shared
              </span>
              <div class="pointer-events-auto flex gap-2">
                <button
                  type="button"
                  data-role="youtube-help"
                  class="btn btn-sm border-white/20 bg-black/75 text-white hover:bg-black"
                >
                  Not playing?
                </button>
                <button
                  type="button"
                  data-role="youtube-fullscreen"
                  class="btn btn-sm border-white/20 bg-black/75 text-white hover:bg-black"
                >
                  <.icon name="hero-arrows-pointing-out" class="size-4" /> Full screen
                </button>
                <button
                  type="button"
                  data-role="end-youtube"
                  class="btn btn-error btn-sm hidden"
                >
                  <.icon name="hero-stop" class="size-4" /> End share
                </button>
              </div>
            </div>
            <button
              type="button"
              data-role="youtube-unlock"
              class="absolute inset-0 z-10 hidden cursor-pointer items-center justify-center bg-black/25 text-white"
            >
              <span
                data-role="youtube-unlock-label"
                class="rounded-full bg-black/80 px-5 py-3 text-sm font-semibold shadow-xl backdrop-blur"
              >
                Tap to watch together
              </span>
            </button>
            <.youtube_playback_assist id="call-youtube-assist" />
          </section>

          <div
            data-role="call-youtube-dialog"
            class="absolute inset-0 z-40 hidden place-items-center bg-black/65 p-4 backdrop-blur-sm"
          >
            <div class="w-full max-w-lg rounded-3xl border border-base-300 bg-base-100 p-5 text-base-content shadow-2xl sm:p-6">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="text-xl font-semibold">Share YouTube</h2>
                  <p class="mt-1 text-sm opacity-65">You will control playback for both of you.</p>
                </div>
                <button
                  type="button"
                  data-role="cancel-youtube"
                  aria-label="Close YouTube sharing"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>
              <div class="mt-5 [&_.fieldset]:mb-0">
                <.input
                  id="call-youtube-input"
                  name="call_youtube_url"
                  type="text"
                  value=""
                  data-role="call-youtube-input"
                  label="YouTube link or video ID"
                  placeholder="https://www.youtube.com/watch?v=..."
                  autocomplete="off"
                />
              </div>
              <p data-role="call-youtube-error" class="mt-2 hidden text-sm text-error"></p>
              <button type="button" data-role="start-youtube" class="btn btn-primary mt-4 w-full">
                <.icon name="hero-play" class="size-4" /> Share video
              </button>
            </div>
          </div>
          <p
            id="call-network-adjustment"
            data-role="call-notice"
            class="absolute bottom-4 left-4 z-10 hidden max-w-sm rounded-2xl border border-white/15 bg-black/75 px-4 py-2 text-sm text-white shadow-lg backdrop-blur"
          >
          </p>

          <aside
            id="call-chat-panel"
            data-role="chat-panel"
            class="absolute inset-y-4 right-4 z-10 hidden w-[min(22rem,calc(100%-2rem))] flex-col overflow-hidden rounded-3xl border border-white/15 bg-base-100/95 text-base-content shadow-2xl backdrop-blur-xl"
          >
            <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
              <div>
                <h2 class="font-semibold">Call chat</h2>
                <p data-role="chat-status" class="text-xs opacity-55">Connecting securely…</p>
              </div>
              <button
                id="call-chat-close"
                type="button"
                data-role="close-chat"
                aria-label="Close call chat"
                class="btn btn-circle btn-ghost btn-sm"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>

            <div
              id="call-chat-messages"
              data-role="chat-messages"
              aria-live="polite"
              class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-3"
            >
              <p data-role="chat-empty" class="m-auto max-w-56 text-center text-sm opacity-50">
                Messages and files travel directly between you and disappear when the call ends.
              </p>
            </div>

            <div
              id="call-chat-dropzone"
              data-role="chat-dropzone"
              class="border-t border-base-300 p-3 transition"
            >
              <div data-role="chat-files" class="mb-2 hidden flex-wrap gap-1.5"></div>
              <div class="flex items-end gap-2">
                <label
                  for="call-chat-files"
                  title="Attach files"
                  class="btn btn-circle btn-ghost btn-sm shrink-0"
                >
                  <.icon name="hero-paper-clip" class="size-5" />
                  <span class="sr-only">Attach files</span>
                </label>
                <input
                  id="call-chat-files"
                  data-role="chat-file-input"
                  type="file"
                  multiple
                  class="sr-only"
                />
                <div class="min-w-0 flex-1 [&_.fieldset]:mb-0">
                  <.input
                    id="call-chat-input"
                    name="call_chat_message"
                    type="textarea"
                    value=""
                    data-role="chat-input"
                    rows="1"
                    maxlength="4000"
                    placeholder="Message or drop files…"
                    class="max-h-28 min-h-10 w-full resize-none rounded-2xl border border-base-300 bg-base-100 px-3 py-2 text-sm outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
                  />
                </div>
                <button
                  id="call-chat-send"
                  type="button"
                  data-role="send-chat"
                  aria-label="Send call message"
                  disabled
                  class="btn btn-circle btn-primary btn-sm shrink-0"
                >
                  <.icon name="hero-paper-airplane" class="size-4" />
                </button>
              </div>
              <p data-role="chat-error" class="mt-2 hidden text-xs text-error" role="alert"></p>
            </div>
          </aside>

          <div
            id="call-device-setup"
            data-role="device-setup"
            class="absolute inset-0 z-20 flex items-center justify-center overflow-y-auto bg-base-300/95 p-4 backdrop-blur-sm"
          >
            <div class="my-auto grid w-full max-w-3xl overflow-hidden rounded-3xl border border-base-300 bg-base-100 shadow-2xl md:grid-cols-[1.15fr_0.85fr]">
              <div class="relative min-h-40 bg-black sm:min-h-56 md:min-h-80">
                <video
                  id="call-setup-preview"
                  data-role="setup-video"
                  autoplay
                  playsinline
                  muted
                  class="absolute inset-0 size-full object-cover"
                ></video>
                <div
                  data-role="setup-video-empty"
                  class="absolute inset-0 hidden items-center justify-center p-6 text-center text-sm text-white/70"
                >
                  Camera preview unavailable
                </div>
              </div>

              <div class="flex flex-col justify-center gap-3 p-4 sm:gap-5 sm:p-7">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-[0.18em] text-primary">
                    Private preview
                  </p>
                  <h2
                    data-role="setup-title"
                    class="mt-1 text-xl font-semibold tracking-tight sm:text-2xl"
                  >
                    Check your devices
                  </h2>
                  <p data-role="setup-help" class="mt-2 text-sm opacity-65">
                    Your preview stays on this device. Choose what you want to use, then join.
                  </p>
                </div>

                <div class="space-y-3">
                  <label class="block" for="call-microphone">
                    <span class="mb-1.5 block text-xs font-semibold uppercase tracking-wide opacity-60">
                      Microphone
                    </span>
                    <select
                      id="call-microphone"
                      data-role="microphone-select"
                      class="w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2.5 text-sm outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
                    >
                      <option>Detecting microphones…</option>
                    </select>
                  </label>

                  <label class="block" for="call-camera">
                    <span class="mb-1.5 block text-xs font-semibold uppercase tracking-wide opacity-60">
                      Camera
                    </span>
                    <select
                      id="call-camera"
                      data-role="camera-select"
                      class="w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2.5 text-sm outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
                    >
                      <option>Detecting cameras…</option>
                    </select>
                  </label>
                  <label
                    data-role="speaker-field"
                    class="hidden"
                    for="call-speaker"
                  >
                    <span class="mb-1.5 block text-xs font-semibold uppercase tracking-wide opacity-60">
                      Speaker
                    </span>
                    <select
                      id="call-speaker"
                      data-role="speaker-select"
                      class="w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2.5 text-sm outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
                    >
                      <option>System default</option>
                    </select>
                  </label>
                </div>

                <div class="flex flex-wrap gap-2">
                  <button
                    id="call-join"
                    type="button"
                    data-role="complete-setup"
                    disabled
                    class="btn btn-primary flex-1 rounded-xl"
                  >
                    Preparing devices…
                  </button>
                  <button
                    id="call-retry-media"
                    type="button"
                    data-role="retry-media"
                    class="btn btn-outline hidden rounded-xl"
                  >
                    Retry
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div
          id="call-controls"
          data-role="call-controls"
          class="flex flex-wrap items-center justify-center gap-3 border-t border-base-300 bg-base-100 px-5 py-4"
        >
          <button
            data-role="toggle-mic"
            title="Mute microphone (M)"
            class="btn btn-outline btn-sm"
          >🎙 Mute</button>
          <button
            data-role="toggle-cam"
            title="Turn camera off (V)"
            class="btn btn-outline btn-sm"
          >🎥 Camera off</button>
          <button
            data-role="switch-cam"
            title="Switch to the next camera"
            class="btn btn-outline btn-sm hidden"
          >
            🔄 Camera
          </button>
          <button
            :if={@can_add_participant}
            id="call-add-someone"
            type="button"
            phx-click="open_add_participant"
            title={"Bring another person into this call (up to #{Calls.max_participants()})"}
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-user-plus" class="size-4" /> Add someone
          </button>
          <button
            data-role="share-screen"
            title="Share your screen or a window"
            class="btn btn-outline btn-sm hidden"
          >
            🖥 Share screen
          </button>
          <button
            id="call-youtube"
            type="button"
            data-role="share-youtube"
            aria-pressed="false"
            disabled
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-play-circle" class="size-4" />
            <span data-role="youtube-share-label">YouTube</span>
          </button>
          <button
            id="call-fit"
            type="button"
            data-role="toggle-fit"
            title="Switch between fitting the whole video and filling the frame"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-arrows-pointing-in" class="size-4" />
            <span data-role="fit-label">Fill</span>
          </button>
          <button
            id="call-chat-toggle"
            type="button"
            data-role="toggle-chat"
            aria-controls="call-chat-panel"
            aria-expanded="false"
            title="Open encrypted call chat (C)"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-chat-bubble-left-right" class="size-4" /> Chat
            <span
              data-role="chat-unread"
              class="hidden min-w-5 rounded-full bg-primary px-1.5 py-0.5 text-[10px] font-bold text-primary-content"
            >
              0
            </span>
          </button>
          <button
            id="call-pip"
            type="button"
            data-role="toggle-pip"
            title="Keep the remote video visible over other windows"
            class="btn btn-outline btn-sm hidden"
          >
            <.icon name="hero-window" class="size-4" />
            <span data-role="pip-label">Picture in picture</span>
          </button>
          <button
            id="call-popout"
            type="button"
            data-role="popout-share"
            title="Open the shared screen in its own window"
            class="btn btn-outline btn-sm hidden"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Pop out
          </button>
          <button
            id="call-fullscreen"
            type="button"
            data-role="toggle-fullscreen"
            title="Show the call fullscreen (F)"
            class="btn btn-outline btn-sm hidden"
          >
            <.icon name="hero-arrows-pointing-out" class="size-4" />
            <span data-role="fullscreen-label">Fullscreen</span>
          </button>
          <button
            id="call-devices"
            type="button"
            data-role="open-devices"
            title="Choose a microphone or camera"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-cog-6-tooth" class="size-4" /> Devices
          </button>
        </div>
      </div>

      <%!--
      Outside #call-session on purpose: that element is phx-update="ignore", so
      a list rendered inside it could never be refreshed as people join.
      --%>
      <div
        :if={@can_add_participant}
        id="call-add-participant"
        role="dialog"
        aria-modal="true"
        aria-labelledby="call-add-participant-title"
        class={[
          "fixed inset-0 z-[1100] items-center justify-center overflow-y-auto bg-base-content/45 p-4 backdrop-blur-sm",
          if(@show_add_participant, do: "flex", else: "hidden")
        ]}
      >
        <div class="my-auto w-full max-w-md rounded-3xl border border-base-300 bg-base-100 p-6 shadow-2xl sm:p-8">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 id="call-add-participant-title" class="text-xl font-semibold tracking-tight">
                Add someone
              </h2>
              <p class="mt-1 text-sm opacity-65">
                Up to {Calls.max_participants()} people can share one call. Whoever you pick is
                rung and still has to accept.
              </p>
            </div>
            <button
              id="call-add-participant-close"
              type="button"
              phx-click="close_add_participant"
              aria-label="Close"
              class="btn btn-circle btn-ghost btn-sm"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <ul :if={@addable_friends != []} class="mt-5 max-h-72 space-y-1 overflow-y-auto">
            <li :for={friend <- @addable_friends}>
              <button
                type="button"
                phx-click="add_participant"
                phx-value-id={friend.id}
                class="flex w-full items-center justify-between gap-3 rounded-2xl px-3 py-2.5 text-left transition hover:bg-base-200"
              >
                <span class="min-w-0">
                  <span class="block truncate font-medium">
                    {friend.display_name || Social.Address.handle(friend)}
                  </span>
                  <%!-- Without a display name the handle is already the label. --%>
                  <span :if={friend.display_name} class="block truncate text-xs opacity-60">
                    {Social.Address.handle(friend)}
                  </span>
                </span>
                <.icon name="hero-phone-arrow-up-right" class="size-4 shrink-0 opacity-60" />
              </button>
            </li>
          </ul>

          <p
            :if={@addable_friends == []}
            class="mt-5 rounded-2xl bg-base-200 px-4 py-3 text-sm opacity-70"
          >
            Nobody left to add: either the call is full, or every contact on this instance is
            already on it. Group calls stay within one instance.
          </p>
        </div>
      </div>

      <p class="mt-3 text-center text-xs opacity-60">
        Audio and video travel directly between you, end-to-end encrypted. Leaving this
        page ends the call and returns you to the conversation.
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"public_id" => public_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user

    case Calls.get_call(user, public_id) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "That call does not exist.")
         |> push_navigate(to: ~p"/messages", replace: true)}

      {:ok, call} ->
        cond do
          params["busy"] == "1" and call.callee_id == user.id ->
            Calls.decline_call(user, public_id, "busy")

            {:ok,
             socket
             |> put_flash(:info, "Sent “Busy now, laters”.")
             |> push_navigate(to: return_to(params, call, user), replace: true)}

          params["reject"] == "1" and call.callee_id == user.id ->
            Calls.decline_call(user, public_id)

            {:ok,
             socket
             |> put_flash(:info, "Call declined.")
             |> push_navigate(to: return_to(params, call, user), replace: true)}

          call.state not in ["ringing", "accepted"] ->
            {:ok,
             socket
             |> put_flash(:error, "That call has already ended.")
             |> push_navigate(to: return_to(params, call, user), replace: true)}

          true ->
            join_and_mount(socket, user, call, params)
        end
    end
  end

  defp join_and_mount(socket, user, call, params) do
    role = if call.caller_id == user.id, do: "caller", else: "callee"
    peer = if role == "caller", do: call.callee, else: call.caller

    if connected?(socket) do
      Calls.subscribe(call)
      Calls.register_presence(call.public_id, user.id)

      cond do
        role == "callee" and call.state == "ringing" ->
          case Calls.join_call(user, call.public_id) do
            {:ok, _call} -> :ok
            # raced with a cancel — the ended broadcast will redirect us
            {:error, _} -> :ok
          end

        role == "caller" and call.state == "accepted" ->
          # The callee already joined — either we reconnected and missed the
          # transient broadcast (common on phones), or they accepted between
          # our dead and connected mounts. Replay it so negotiation starts.
          send(self(), {:call_peer_joined, call.public_id, call.callee_id})

        role == "callee" and call.state == "accepted" ->
          # A full reload can lose the caller's first offer. Re-announce this
          # accepted callee so the caller can restart negotiation.
          Calls.rejoin_call(user, call.public_id)

        true ->
          :ok
      end
    end

    {:ok,
     socket
     |> assign(
       page_title: "Call",
       call: call,
       role: role,
       peer: peer,
       actor: user,
       local_id: user.id,
       layout_scope: socket.assigns.current_scope,
       is_guest: false,
       allow_reinvite: true,
       can_add_participant: call.caller_id == user.id,
       show_add_participant: false,
       return_to: return_to(params, call, user),
       ice_servers: Jason.encode!(Veejr.Calls.IceConfig.servers())
     )
     |> refresh_peers()}
  end

  # The mesh needs every other participant's identity key to seal signaling
  # pairwise, so the peer list is an assign the hook reads rather than
  # something it can ask for.
  defp refresh_peers(socket) do
    call = socket.assigns.call
    me = socket.assigns.actor

    peers =
      case me do
        %{id: user_id} when is_integer(user_id) ->
          call
          |> Calls.peer_participants(user_id)
          |> Enum.map(fn participant ->
            %{
              id: participant.user_id,
              name:
                participant.user.display_name || Veejr.Social.Address.handle(participant.user),
              public_key: participant.user.public_key,
              state: participant.state
            }
          end)

        _ ->
          []
      end

    socket
    |> assign(peers: peers, addable_friends: addable_friends(socket, call, peers))
    # The hook cannot re-read `data-peers`: its element is phx-update="ignore".
    # The roster is pushed instead, and is what drives connect and disconnect.
    |> push_event("call:peers", %{peers: peers})
  end

  defp addable_friends(socket, call, peers) do
    if socket.assigns[:can_add_participant] and length(peers) + 1 < Calls.max_participants() do
      taken = MapSet.new(Enum.map(peers, & &1.id))

      socket.assigns.actor
      |> Veejr.Social.list_friends()
      |> Enum.filter(
        &(is_nil(&1.host) and not MapSet.member?(taken, &1.id) and &1.id != call.caller_id)
      )
    else
      []
    end
  end

  @impl true
  def handle_event("signal", %{"ciphertext" => ciphertext, "nonce" => nonce} = params, socket) do
    user = socket.assigns.current_scope.user
    target = parse_target(params["target"])

    case Calls.signal(user, socket.assigns.call.public_id, ciphertext, nonce, target) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("open_add_participant", _params, socket) do
    # Refreshed on open so the list cannot offer someone who joined or left
    # while the page sat there.
    {:noreply, socket |> refresh_peers() |> assign(show_add_participant: true)}
  end

  def handle_event("close_add_participant", _params, socket) do
    {:noreply, assign(socket, show_add_participant: false)}
  end

  def handle_event("add_participant", %{"id" => invitee_id}, socket) do
    user = socket.assigns.current_scope.user

    case Calls.add_participant(user, socket.assigns.call.public_id, invitee_id) do
      {:ok, _call} ->
        {:noreply,
         socket
         |> refresh_peers()
         |> assign(show_add_participant: false)
         |> put_flash(:info, "Ringing them now.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_peers()
         |> put_flash(:error, add_participant_error(reason))}
    end
  end

  def handle_event("hangup", _params, socket) do
    user = socket.assigns.current_scope.user
    call_id = socket.assigns.call.public_id

    cancelled? =
      socket.assigns.role == "caller" and
        match?({:ok, _call}, Calls.cancel_call(user, call_id))

    unless cancelled?, do: Calls.end_call(user, call_id)

    {:noreply,
     socket
     |> put_flash(:info, if(cancelled?, do: "Call invitation cancelled.", else: "Call ended."))
     |> push_navigate(to: socket.assigns.return_to, replace: true)}
  end

  def handle_event("reinvite", _params, socket) do
    user = socket.assigns.current_scope.user
    call = socket.assigns.call

    if call.caller_id == user.id do
      case Calls.start_call(user, call.callee_id) do
        {:ok, new_call} ->
          {:noreply,
           push_navigate(socket,
             to: ~p"/call/#{new_call.public_id}?#{%{return_to: socket.assigns.return_to}}",
             replace: true
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, reinvite_error(reason))
           |> push_event("call:reinvite_failed", %{})}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:call_peer_joined, _id, participant_id}, socket) do
    me = socket.assigns.current_scope.user.id

    if participant_id == me do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> refresh_peers()
       |> push_event("call:peer_joined", %{peer: participant_id})}
    end
  end

  def handle_info({:call_participants_changed, _id}, socket) do
    {:noreply, refresh_peers(socket)}
  end

  def handle_info({:call_participant_left, _id, departed_id}, socket) do
    if departed_id == socket.assigns.current_scope.user.id do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> refresh_peers()
       |> push_event("call:peer_left", %{peer: departed_id})}
    end
  end

  def handle_info({:call_signal, _id, from_id, target_id, ciphertext, nonce}, socket) do
    me = socket.assigns.current_scope.user.id

    # Deliver only what is addressed to us. Without this filter a third
    # participant would receive the other two's offers and try to apply them.
    if from_id == me or target_id not in [:any, me] do
      {:noreply, socket}
    else
      {:noreply,
       push_event(socket, "call:signal", %{
         ciphertext: ciphertext,
         nonce: nonce,
         from: from_id
       })}
    end
  end

  def handle_info({:call_ended, _id, reason}, socket) do
    message =
      case reason do
        "declined" -> "Call declined."
        "busy" -> "Busy now, laters."
        "cancelled" -> "Call invitation cancelled."
        "missed" -> "Call ended before it was answered."
        _ -> "Call ended."
      end

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: socket.assigns.return_to, replace: true)}
  end

  def handle_info({:call_disconnected, _id, departed_user_id}, socket) do
    call = socket.assigns.call
    user = socket.assigns.current_scope.user

    if user.id == call.caller_id and departed_user_id == call.callee_id do
      {:noreply, push_event(socket, "call:peer_disconnected", %{})}
    else
      {:noreply,
       socket
       |> put_flash(:info, "The call ended after the connection was lost.")
       |> push_navigate(to: socket.assigns.return_to, replace: true)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp parse_target(nil), do: nil
  defp parse_target(id) when is_integer(id), do: id

  defp parse_target(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_target(_), do: nil

  defp add_participant_error(:not_caller), do: "Only whoever started the call can add someone."
  defp add_participant_error(:not_a_friend), do: "You can only add an accepted friend."
  defp add_participant_error(:remote_participant), do: "Group calls are limited to this instance."
  defp add_participant_error(:already_participating), do: "They are already on this call."
  defp add_participant_error(:call_full), do: "This call is already full."
  defp add_participant_error({:bad_state, _}), do: "That call is no longer active."
  defp add_participant_error(_), do: "Could not add them to the call."

  defp return_to(params, call, user) do
    fallback = conversation_path(call, user)

    case URI.parse(params["return_to"] || "") do
      %URI{scheme: nil, host: nil, path: "/messages", fragment: nil} = uri ->
        URI.to_string(uri)

      _uri ->
        fallback
    end
  end

  defp conversation_path(call, user) do
    peer = if call.caller_id == user.id, do: call.callee, else: call.caller
    key = Messaging.conversation_key([Social.Address.handle(peer)])

    ~p"/messages?conversation=#{key}"
  end

  defp reinvite_error(:callee_unreachable),
    do: "The other instance could not be reached. Try again shortly."

  defp reinvite_error(:not_a_friend), do: "This person is no longer in your contacts."
  defp reinvite_error(_reason), do: "The new invitation could not be sent. Please try again."

  @impl true
  def terminate(_reason, socket) do
    # Leaving the page hangs up — but only after a grace period with no
    # reconnect, so a phone's socket blip doesn't kill the call. Calls that
    # already ended are untouched.
    if call = socket.assigns[:call] do
      Calls.end_call_after_grace(socket.assigns.current_scope.user, call.public_id)
    end

    :ok
  end
end
