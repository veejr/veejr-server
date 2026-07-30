defmodule VeejrWeb.MessagingComponents do
  @moduledoc """
  Shared UI for encrypted content: the composer form and envelope rendering.

  The composer is deliberately NOT a LiveView form — its inputs are read by
  the `Composer` JS hook, encrypted in the browser, and only ciphertext is
  pushed to the server.
  """
  use Phoenix.Component
  import VeejrWeb.CoreComponents, only: [icon: 1, user_avatar: 1]

  alias Veejr.Accounts.User
  alias Veejr.Messaging.Envelope
  alias Veejr.Social

  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :conversations, :list, required: true
  attr :friends, :list, required: true
  attr :groups, :list, required: true
  attr :submit_event, :string, default: "start_conversation"

  def conversation_builder(assigns) do
    ~H"""
    <details id={@id} class="dropdown dropdown-end">
      <summary class="btn btn-primary btn-sm list-none">
        <.icon name="hero-chat-bubble-left-right" class="size-4" /> New conversation
        <.icon name="hero-chevron-down" class="size-3.5" />
      </summary>
      <form
        id={@form_id}
        phx-submit={@submit_event}
        class="app-menu-surface dropdown-content z-40 mt-2 w-[min(22rem,calc(100vw-2rem))] rounded-lg border p-3"
      >
        <div class="max-h-80 space-y-4 overflow-y-auto pr-1">
          <fieldset :if={@conversations != []}>
            <legend class="mb-1 px-2 text-xs font-semibold uppercase opacity-60">
              Conversations
            </legend>
            <label
              :for={conversation <- @conversations}
              class="flex cursor-pointer items-center gap-3 rounded-md px-2 py-2 text-sm hover:bg-base-200"
            >
              <input
                type="checkbox"
                name="selection[conversation_keys][]"
                value={conversation.key}
                class="checkbox checkbox-sm"
              />
              <span class="min-w-0 flex-1 truncate">{conversation_title(conversation)}</span>
            </label>
          </fieldset>

          <fieldset :if={@friends != []}>
            <legend class="mb-1 px-2 text-xs font-semibold uppercase opacity-60">
              Friends
            </legend>
            <label
              :for={friend <- @friends}
              class="flex cursor-pointer items-center gap-3 rounded-md px-2 py-2 text-sm hover:bg-base-200"
            >
              <input
                type="checkbox"
                name="selection[friend_ids][]"
                value={friend.id}
                class="checkbox checkbox-sm"
              />
              <span class="min-w-0 flex-1 truncate">
                {friend.display_name || Social.Address.handle(friend)}
              </span>
            </label>
          </fieldset>

          <fieldset :if={@groups != []}>
            <legend class="mb-1 px-2 text-xs font-semibold uppercase opacity-60">
              Groups
            </legend>
            <label
              :for={group <- @groups}
              class="flex cursor-pointer items-center gap-3 rounded-md px-2 py-2 text-sm hover:bg-base-200"
            >
              <input
                type="checkbox"
                name="selection[group_ids][]"
                value={group.id}
                class="checkbox checkbox-sm"
              />
              <span class="min-w-0 flex-1 truncate">{group.name}</span>
              <span class="text-xs opacity-50">{length(group.members)}</span>
            </label>
          </fieldset>

          <p
            :if={@conversations == [] and @friends == [] and @groups == []}
            class="px-2 py-4 text-center text-sm opacity-60"
          >
            Add a friend or group first.
          </p>
        </div>
        <button
          type="submit"
          class="btn btn-primary btn-sm mt-3 w-full"
          disabled={@conversations == [] and @friends == [] and @groups == []}
        >
          Open conversation
        </button>
      </form>
    </details>
    """
  end

  defp conversation_title(conversation) do
    title = Enum.join(conversation.participants, ", ")

    if conversation.preserved do
      "#{title} · #{Calendar.strftime(conversation.started_at, "%b %d, %Y")}"
    else
      title
    end
  end

  attr :id, :string, required: true
  attr :user, User, required: true
  attr :friends, :list, required: true
  attr :groups, :list, required: true
  attr :kind, :string, default: "message"
  attr :payload, :string, default: nil, doc: "JSON merged into the payload (e.g. map coords)"
  attr :selected_friend_ids, :list, default: []
  attr :selected_group_ids, :list, default: []
  attr :selected_self, :boolean, default: false
  attr :show_recipients, :boolean, default: true
  attr :recipient_layout, :string, default: "pills"
  attr :surface, :string, default: "card"
  attr :show_text, :boolean, default: true
  attr :show_files, :boolean, default: true
  attr :draft_key, :string, default: nil

  attr :text_placeholder, :string,
    default: "Write something… it is encrypted before it leaves this browser."

  attr :submit_label, :string, default: "Encrypt & send"

  def composer(assigns) do
    assigns =
      assigns
      |> assign(
        :can_send?,
        if assigns.show_recipients do
          true
        else
          assigns.selected_self or assigns.selected_friend_ids != [] or
            assigns.selected_group_ids != []
        end
      )
      # The browser needs the instance's limit to refuse an oversize file
      # before encrypting and uploading it, rather than after a 413.
      |> assign(:max_upload_bytes, Veejr.InstanceSettings.max_upload_bytes())

    ~H"""
    <form
      id={@id}
      phx-hook="Composer"
      data-user-id={@user.id}
      data-my-key={@user.public_key}
      data-kind={@kind}
      data-payload={@payload}
      data-draft-key={@draft_key}
      data-max-upload-bytes={@max_upload_bytes}
      data-composer-dropzone={@show_files && ""}
      data-drop-label="Drop to attach"
      data-enc-secret-key={@user.enc_secret_key}
      data-key-salt={@user.key_salt}
      data-key-nonce={@user.key_nonce}
      class={[
        "relative space-y-3",
        @surface == "messages" &&
          "rounded-[28px] border border-base-300 bg-base-100 p-3 shadow-sm",
        @surface != "messages" &&
          "rounded-lg border border-base-300 p-4"
      ]}
    >
      <p data-role="error" class="hidden text-error text-sm"></p>
      <%!--
      Unlocking used to mean a trip to /keys, which threw away the message and
      any attachments on the way. The passphrase is read straight from this
      input and never becomes a LiveView event, exactly as on the keys page.
      --%>
      <div
        data-role="composer-unlock"
        class="hidden flex-wrap items-center gap-2 rounded-2xl border border-primary/25 bg-primary/5 p-2"
      >
        <span class="px-1 text-xs font-medium opacity-70">
          <.icon name="hero-lock-closed" class="mr-1 inline size-3.5" /> Unlock to send
        </span>
        <input
          type="password"
          data-role="composer-passphrase"
          aria-label="Encryption passphrase"
          autocomplete="current-password"
          placeholder="Encryption passphrase"
          class="min-w-0 flex-1 rounded-full border border-base-300 bg-base-100 px-3 py-1.5 text-sm outline-none focus:border-primary focus:ring-2 focus:ring-primary/20"
        />
        <button type="button" data-role="composer-unlock-submit" class="btn btn-primary btn-sm">
          Unlock and send
        </button>
        <button type="button" data-role="composer-unlock-cancel" class="btn btn-ghost btn-sm">
          Cancel
        </button>
        <p
          data-role="composer-unlock-error"
          role="alert"
          class="hidden w-full px-1 text-xs text-error"
        >
        </p>
      </div>
      <div
        :if={@kind == "message"}
        data-role="reply-preview"
        class="hidden flex items-center gap-3 rounded-2xl border border-primary/25 bg-primary/5 px-3 py-2"
      >
        <div class="min-w-0 flex-1 border-l-2 border-primary pl-3">
          <p data-role="reply-from" class="truncate text-xs font-semibold text-primary"></p>
          <p data-role="reply-text" class="truncate text-xs opacity-70"></p>
        </div>
        <button
          type="button"
          data-role="cancel-reply"
          aria-label="Cancel reply"
          class="rounded-full p-1 transition hover:bg-base-300"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
      <div
        :if={@kind != "self_note"}
        data-role="message-options"
        class="hidden rounded-2xl border border-base-300 bg-base-200 p-3"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="text-xs font-medium uppercase tracking-wide opacity-70">
            Available for
            <select
              data-role="ttl"
              class="mt-1 w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2 text-sm font-normal normal-case tracking-normal text-base-content outline-none transition focus:ring-2 focus:ring-primary/30"
            >
              <option value="">No time limit</option>
              <option value="300">5 minutes</option>
              <option value="3600">1 hour</option>
              <option value="86400">1 day</option>
              <option value="604800">1 week</option>
            </select>
          </label>
          <label class="text-xs font-medium uppercase tracking-wide opacity-70">
            Displays
            <input
              data-role="max-displays"
              type="number"
              min="1"
              max="100"
              inputmode="numeric"
              placeholder="Unlimited"
              class="mt-1 w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2 text-sm font-normal normal-case tracking-normal text-base-content outline-none transition placeholder:opacity-50 focus:ring-2 focus:ring-primary/30"
            />
          </label>
        </div>
        <div class="mt-3 border-t border-base-300 pt-3">
          <label class="text-xs font-medium uppercase tracking-wide opacity-70">
            Send later
            <input
              data-role="deliver-at"
              type="datetime-local"
              class="mt-1 w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2 text-sm font-normal normal-case tracking-normal text-base-content outline-none transition focus:ring-2 focus:ring-primary/30"
            />
          </label>
          <p data-role="schedule-summary" class="mt-2 text-xs leading-5 opacity-70">
            Sends immediately. A scheduled message is encrypted now and held as ciphertext
            until its time; the server never sees the text.
          </p>
        </div>
        <p data-role="expiry-summary" class="mt-3 text-xs leading-5 opacity-70">
          No expiry or display limit. Limits cannot revoke content a recipient has already saved.
        </p>
      </div>

      <input
        :if={!@show_recipients && @selected_self}
        type="hidden"
        name="self"
        value="true"
      />
      <input
        :for={id <- @selected_friend_ids}
        :if={!@show_recipients}
        type="hidden"
        name="friends[]"
        value={id}
      />
      <input
        :for={id <- @selected_group_ids}
        :if={!@show_recipients}
        type="hidden"
        name="groups[]"
        value={id}
      />

      <div :if={@show_recipients && @recipient_layout == "dropdown"} class="dropdown w-full">
        <div
          tabindex="0"
          role="button"
          class="btn btn-outline btn-sm flex w-full justify-between sm:w-64"
        >
          <span>Recipients</span>
          <.icon name="hero-chevron-down" class="size-4" />
        </div>
        <div
          tabindex="0"
          class="app-menu-surface dropdown-content z-30 mt-2 max-h-80 w-full overflow-y-auto rounded-box border p-3 sm:w-80"
        >
          <div class="space-y-3">
            <div>
              <p class="mb-1 text-xs font-medium uppercase tracking-wide opacity-70">
                This account
              </p>
              <label class="flex cursor-pointer items-center justify-between gap-3 rounded-md px-2 py-1.5 text-sm hover:bg-base-200">
                <span>Me</span>
                <input
                  type="checkbox"
                  name="self"
                  value="true"
                  checked={@selected_self}
                  class="checkbox checkbox-sm"
                />
              </label>
            </div>

            <div :if={@friends != []}>
              <p class="mb-1 text-xs font-medium uppercase tracking-wide opacity-70">
                Friends
              </p>
              <label
                :for={friend <- @friends}
                class="flex cursor-pointer items-center justify-between gap-3 rounded-md px-2 py-1.5 text-sm hover:bg-base-200"
              >
                <span>{friend.display_name || friend.username}</span>
                <input
                  type="checkbox"
                  name="friends[]"
                  value={friend.id}
                  checked={to_string(friend.id) in @selected_friend_ids}
                  class="checkbox checkbox-sm"
                />
              </label>
            </div>

            <div :if={@groups != []}>
              <p class="mb-1 text-xs font-medium uppercase tracking-wide opacity-70">
                Groups
              </p>
              <label
                :for={group <- @groups}
                class="flex cursor-pointer items-center justify-between gap-3 rounded-md px-2 py-1.5 text-sm hover:bg-base-200"
              >
                <span>{group.name} ({length(group.members)})</span>
                <input
                  type="checkbox"
                  name="groups[]"
                  value={group.id}
                  checked={to_string(group.id) in @selected_group_ids}
                  class="checkbox checkbox-sm"
                />
              </label>
            </div>

            <p :if={@friends == []} class="px-2 text-sm opacity-70">
              You can send to yourself. Add friends on the Friends page to send to others.
            </p>
          </div>
        </div>
      </div>

      <div :if={@show_recipients && @recipient_layout == "pills"} class="space-y-2">
        <p class="px-2 text-xs font-medium uppercase tracking-wide opacity-70">
          This account
        </p>
        <label class={[
          "flex w-fit cursor-pointer items-center gap-2 rounded-full border px-3 py-1.5 text-sm transition",
          @selected_self && "border-primary/20 bg-primary/10 text-base-content",
          !@selected_self && "border-base-300 bg-base-200 text-base-content hover:bg-base-300"
        ]}>
          <input
            type="checkbox"
            name="self"
            value="true"
            checked={@selected_self}
            class="checkbox checkbox-xs border-base-300"
          /> Me
        </label>
      </div>

      <div
        :if={@show_recipients && @recipient_layout == "pills" && @friends == []}
        class="px-2 text-sm opacity-70"
      >
        You can send to yourself. Add friends on the Friends page to send to others.
      </div>

      <div :if={@show_recipients && @recipient_layout == "pills" && @friends != []}>
        <p class="mb-2 px-2 text-xs font-medium uppercase tracking-wide opacity-70">
          Friends
        </p>
        <div class="flex flex-wrap gap-2">
          <label
            :for={friend <- @friends}
            class={[
              "flex cursor-pointer items-center gap-2 rounded-full border px-3 py-1.5 text-sm transition",
              to_string(friend.id) in @selected_friend_ids &&
                "border-primary/20 bg-primary/10 text-base-content",
              to_string(friend.id) not in @selected_friend_ids &&
                "border-base-300 bg-base-200 text-base-content hover:bg-base-300"
            ]}
          >
            <input
              type="checkbox"
              name="friends[]"
              value={friend.id}
              checked={to_string(friend.id) in @selected_friend_ids}
              class="checkbox checkbox-xs border-base-300"
            />
            {friend.display_name || friend.username}
          </label>
        </div>
      </div>

      <div :if={@show_recipients && @recipient_layout == "pills" && @groups != []}>
        <p class="mb-2 px-2 text-xs font-medium uppercase tracking-wide opacity-70">
          Groups
        </p>
        <div class="flex flex-wrap gap-2">
          <label
            :for={group <- @groups}
            class="flex cursor-pointer items-center gap-2 rounded-full border border-base-300 bg-base-200 px-3 py-1.5 text-sm text-base-content transition hover:bg-base-300"
          >
            <input
              type="checkbox"
              name="groups[]"
              value={group.id}
              checked={to_string(group.id) in @selected_group_ids}
              class="checkbox checkbox-xs border-base-300"
            />
            {group.name} ({length(group.members)})
          </label>
        </div>
      </div>

      <div class={[
        @surface == "messages" && "flex flex-wrap items-end gap-2 sm:flex-nowrap",
        @surface != "messages" && "space-y-3"
      ]}>
        <button
          :if={@surface == "messages" && @kind != "self_note"}
          type="button"
          data-role="toggle-options"
          title="Message options"
          aria-label="Message options"
          class="messages-composer-action order-1 flex size-11 shrink-0 items-center justify-center rounded-full transition sm:order-none"
        >
          <.icon name="hero-adjustments-horizontal" class="size-5" />
        </button>

        <div
          :if={@show_text && @surface == "messages"}
          class="relative order-2 min-w-0 basis-full sm:order-none sm:flex-1 sm:basis-auto"
        >
          <textarea
            data-role="text"
            rows="1"
            aria-label="Message"
            aria-keyshortcuts="Enter"
            class="textarea min-h-11 w-full resize-none rounded-[22px] border-0 bg-base-200 py-3 pl-4 pr-12 text-base-content placeholder:opacity-50 focus:outline-none focus:ring-2 focus:ring-primary/30"
            placeholder={@text_placeholder}
          ></textarea>

          <button
            type="button"
            data-role="emoji-toggle"
            title="Add emoji"
            aria-label="Add emoji"
            aria-expanded="false"
            class="absolute bottom-1.5 right-1.5 flex size-8 items-center justify-center rounded-full text-lg transition hover:bg-base-300"
          >
            🙂
          </button>
          <div
            data-role="emoji-menu"
            class="absolute bottom-11 right-0 z-20 hidden w-56 rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg"
          >
            <div class="grid grid-cols-7 gap-1">
              <button
                :for={emoji <- ~w(😀 😄 😂 😊 😍 😎 🤔 😢 😡 👍 👎 🙌 👏 🙏 ❤️ 🔥 🎉 ✨ 👀 💯)}
                type="button"
                data-role="emoji-option"
                data-emoji={emoji}
                class="flex size-7 items-center justify-center rounded text-base transition hover:bg-base-200"
              >
                {emoji}
              </button>
            </div>
          </div>
        </div>

        <textarea
          :if={@show_text && @surface != "messages"}
          data-role="text"
          rows="3"
          class="textarea textarea-bordered w-full resize-none"
          placeholder={@text_placeholder}
        ></textarea>

        <div :if={@show_text && @surface != "messages"} class="relative shrink-0">
          <button
            type="button"
            data-role="emoji-toggle"
            title="Add emoji"
            aria-label="Add emoji"
            aria-expanded="false"
            class="flex size-11 items-center justify-center rounded-full border border-base-300 bg-base-200 text-lg transition hover:bg-base-300"
          >
            🙂
          </button>
          <div
            data-role="emoji-menu"
            class="absolute bottom-12 right-0 z-20 hidden w-56 rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg"
          >
            <div class="grid grid-cols-7 gap-1">
              <button
                :for={emoji <- ~w(😀 😄 😂 😊 😍 😎 🤔 😢 😡 👍 👎 🙌 👏 🙏 ❤️ 🔥 🎉 ✨ 👀 💯)}
                type="button"
                data-role="emoji-option"
                data-emoji={emoji}
                class="flex size-7 items-center justify-center rounded text-base transition hover:bg-base-200"
              >
                {emoji}
              </button>
            </div>
          </div>
        </div>

        <label
          :if={@show_files && @surface == "messages"}
          data-role="file-toggle"
          title="Attach files"
          aria-label="Attach files"
          class="messages-composer-action order-1 flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-full transition sm:order-none"
        >
          <.icon name="hero-paper-clip" class="size-5" />
          <span class="sr-only">Attach files</span>
          <input type="file" data-role="files" multiple class="sr-only" />
        </label>

        <button
          :if={@show_files && @surface == "messages"}
          type="button"
          data-role="audio-toggle"
          title="Record voice message"
          aria-label="Record voice message"
          aria-pressed="false"
          class="messages-composer-action order-1 flex size-11 shrink-0 items-center justify-center rounded-full transition sm:order-none"
        >
          <.icon name="hero-microphone" class="size-5" />
        </button>

        <button
          :if={@show_files && @surface == "messages"}
          type="button"
          data-role="video-toggle"
          title="Record video message"
          aria-label="Record video message"
          aria-pressed="false"
          class="messages-composer-action order-1 flex size-11 shrink-0 items-center justify-center rounded-full transition sm:order-none"
        >
          <.icon name="hero-video-camera" class="size-5" />
        </button>

        <button
          :if={@show_files && @surface == "messages"}
          type="button"
          data-role="video-facing-toggle"
          title="Switch camera for next recording"
          aria-label="Switch camera for next recording"
          class="messages-composer-action order-1 flex size-11 shrink-0 items-center justify-center rounded-full transition sm:order-none"
        >
          <.icon name="hero-arrow-path-rounded-square" class="size-5" />
        </button>

        <input
          :if={@show_files && @surface != "messages"}
          type="file"
          data-role="files"
          multiple
          class="file-input file-input-sm w-full"
        />

        <button
          :if={@show_files && @surface != "messages"}
          type="button"
          data-role="audio-toggle"
          aria-pressed="false"
          class="btn btn-outline btn-sm"
        >
          <.icon name="hero-microphone" class="size-4" /> Record audio
        </button>

        <div :if={@show_files && @surface != "messages"} class="flex flex-wrap gap-2">
          <button
            type="button"
            data-role="video-toggle"
            aria-pressed="false"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-video-camera" class="size-4" /> Record video
          </button>
          <button
            type="button"
            data-role="video-facing-toggle"
            title="Switch camera for next recording"
            aria-label="Switch camera for next recording"
            class="btn btn-ghost btn-sm btn-square"
          >
            <.icon name="hero-arrow-path-rounded-square" class="size-4" />
          </button>
        </div>

        <button
          :if={@surface != "messages"}
          type="submit"
          class="btn btn-primary"
          disabled={!@can_send?}
        >
          {@submit_label}
        </button>
      </div>

      <p
        :if={@surface == "messages" && @show_text}
        class="px-2 text-[0.7rem] opacity-50"
      >
        Enter to send · Shift+Enter for a new line
        <span data-role="draft-status" class="hidden" aria-live="polite"></span>
      </p>

      <div
        :if={@show_files}
        data-role="audio-status"
        class="hidden px-2 text-xs opacity-70"
      >
      </div>
      <div :if={@show_files} data-role="audio-preview" class="space-y-2"></div>
      <div
        :if={@show_files}
        data-role="video-status"
        aria-live="polite"
        class="hidden px-2 text-xs opacity-70"
      >
      </div>
      <div :if={@show_files} data-role="video-preview" class="space-y-2"></div>
      <%!--
      Attached files were invisible until send on the messages surface, where
      the input is sr-only behind the paper clip. Pasting into a composer that
      shows nothing back reads as a broken paste, so the strip comes first.
      --%>
      <div
        :if={@show_files}
        data-role="file-preview"
        aria-live="polite"
        class="hidden flex-wrap gap-2"
      >
      </div>
    </form>
    """
  end

  attr :envelope, Envelope, required: true, doc: "sender preloaded"
  attr :user, User, required: true
  attr :label, :string, required: true
  attr :conversation_path, :string, required: true

  def envelope_item(assigns) do
    ~H"""
    <li class="rounded-lg border border-base-300 p-3">
      <div class="flex flex-wrap items-center justify-between gap-2 text-sm text-base-content/70">
        <span>{kind_icon(@envelope.kind)} {@label}</span>
        <span class="flex flex-wrap items-center gap-3">
          <span>{Calendar.strftime(@envelope.inserted_at, "%b %d, %H:%M")} UTC</span>
          <.link
            id={"history-open-#{@envelope.public_id}"}
            navigate={@conversation_path}
            class="inline-flex items-center gap-1 font-medium text-primary hover:underline"
          >
            Open conversation <.icon name="hero-arrow-right" class="size-3.5" />
          </.link>
        </span>
      </div>
      <div
        id={"env-#{@envelope.public_id}"}
        phx-hook="Decrypt"
        phx-update="ignore"
        data-user-id={@user.id}
        data-peer-key={Veejr.Messaging.peer_key(@envelope, @user)}
        data-ciphertext={@envelope.ciphertext}
        data-nonce={@envelope.nonce}
        data-kind={@envelope.kind}
        data-public-id={@envelope.public_id}
        data-expires-at={expiry_iso8601(@envelope.expires_at)}
        class="mt-2"
      >
        <span class="loading loading-dots loading-xs"></span>
      </div>
    </li>
    """
  end

  def kind_icon("message"), do: "✉️"
  def kind_icon("location"), do: "📍"
  def kind_icon("note"), do: "📝"
  def kind_icon(_), do: "✉️"

  @doc """
  A single message rendered as a chat bubble: your own messages align right
  in the accent color, others align left with the sender's handle. The bubble
  body is filled in by the `Decrypt` hook — plaintext never reaches the server.
  """
  attr :envelope, Envelope, required: true, doc: "sender preloaded"
  attr :user, User, required: true
  attr :mine, :boolean, required: true
  attr :profile_click, :string, default: nil

  def message_bubble(assigns) do
    ~H"""
    <div
      id={"message-shell-#{@envelope.public_id}"}
      phx-hook="MessageBubble"
      data-message-mine={to_string(@mine)}
      data-message-sender={Veejr.Social.Address.handle(@envelope.sender)}
      class={["flex", @mine && "justify-end", !@mine && "items-start gap-2"]}
    >
      <.user_avatar
        :if={!@mine}
        user={@envelope.sender}
        class="mt-5 size-8 text-xs"
        on_click={@profile_click}
      />
      <.user_avatar
        :if={@mine}
        user={@user}
        data-role="salon-self-avatar"
        class="salon-self-avatar mt-5 hidden size-8 text-xs"
        on_click={@profile_click}
      />
      <div class={[
        "veejr-message-content flex min-w-0 flex-1 flex-col",
        @mine && "items-end",
        !@mine && "items-start"
      ]}>
        <div :if={!@mine} class="veejr-bubble-author mb-1 ml-3 text-xs font-medium opacity-70">
          {Veejr.Social.Address.handle(@envelope.sender)}
        </div>
        <div
          :if={@mine}
          data-role="salon-self-author"
          class="veejr-bubble-author salon-self-author mb-1 ml-3 hidden text-xs font-medium"
        >
          {Veejr.Social.Address.handle(@user)}
        </div>
        <div class={[
          "veejr-bubble max-w-[78%] rounded-[22px] px-4 py-2 text-[0.95rem] leading-relaxed shadow-sm",
          @mine && "veejr-bubble-mine rounded-br-md bg-primary text-primary-content",
          !@mine &&
            "veejr-bubble-peer rounded-bl-md bg-base-100 text-base-content ring-1 ring-base-300"
        ]}>
          <p
            :if={@envelope.kind != "message"}
            class="mb-0.5 text-xs font-medium uppercase tracking-wide opacity-60"
          >
            {kind_label(@envelope.kind)}
          </p>
          <div
            id={"env-#{@envelope.public_id}"}
            phx-hook="Decrypt"
            phx-update="ignore"
            data-user-id={@user.id}
            data-peer-key={Veejr.Messaging.peer_key(@envelope, @user)}
            data-ciphertext={@envelope.ciphertext}
            data-nonce={@envelope.nonce}
            data-kind={@envelope.kind}
            data-public-id={@envelope.public_id}
            data-expires-at={expiry_iso8601(@envelope.expires_at)}
          >
            <span class="loading loading-dots loading-xs"></span>
          </div>
        </div>
        <div
          class={[
            "veejr-bubble-meta mt-1 text-xs opacity-60",
            @mine && "mr-3",
            !@mine && "ml-3"
          ]}
          id={"message-meta-#{@envelope.public_id}"}
        >
          <time
            datetime={DateTime.to_iso8601(@envelope.inserted_at)}
            data-role="message-timestamp"
          >
            {Calendar.strftime(@envelope.inserted_at, "%b %d, %Y · %H:%M UTC")}
          </time>
          <span :if={@envelope.edited_at} class="ml-1">edited</span>
          <span :if={@envelope.expires_at} class="ml-1">
            <.icon name="hero-clock" class="inline size-3.5" />
          </span>
          <span :if={@envelope.max_displays} class="ml-1">
            <.icon name="hero-eye" class="inline size-3.5" /> {@envelope.max_displays -
              @envelope.display_count}
          </span>
          <button
            type="button"
            data-role="reply-message"
            title="Reply"
            aria-label="Reply"
            class="ml-1 rounded-full p-1 transition hover:bg-base-300 hover:opacity-100"
          >
            <.icon name="hero-arrow-uturn-left" class="size-3.5" />
          </button>
          <button
            :if={@mine}
            type="button"
            data-role="edit-message"
            title="Edit message"
            aria-label="Edit message"
            class="ml-2 rounded-full p-1 transition hover:bg-base-300 hover:opacity-100"
          >
            <.icon name="hero-pencil-square" class="size-3.5" />
          </button>
          <button
            type="button"
            phx-click="delete_envelope"
            phx-value-id={@envelope.public_id}
            data-confirm={delete_confirm(@mine)}
            title={delete_label(@mine)}
            aria-label={delete_label(@mine)}
            class="ml-1 rounded-full p-1 transition hover:bg-base-300 hover:opacity-100"
          >
            <.icon name={if(@mine, do: "hero-trash", else: "hero-eye-slash")} class="size-3.5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :envelope, Envelope, required: true
  attr :user, User, required: true

  def self_note_card(assigns) do
    ~H"""
    <article
      id={"self-note-#{@envelope.public_id}"}
      class="self-note-card break-inside-avoid rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md"
    >
      <div
        id={"self-note-content-#{@envelope.public_id}"}
        phx-hook="SelfNotes"
        phx-update="ignore"
        data-user-id={@user.id}
        data-peer-key={Veejr.Messaging.peer_key(@envelope, @user)}
        data-ciphertext={@envelope.ciphertext}
        data-nonce={@envelope.nonce}
        data-public-id={@envelope.public_id}
        data-updated-at={DateTime.to_iso8601(@envelope.updated_at)}
        data-kind={@envelope.kind}
        data-remind-at={@envelope.remind_at && DateTime.to_iso8601(@envelope.remind_at)}
      >
        <span class="loading loading-dots loading-xs"></span>
      </div>
    </article>
    """
  end

  defp expiry_iso8601(nil), do: nil
  defp expiry_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp kind_label("location"), do: "📍 Location"
  defp kind_label("note"), do: "📝 Map note"
  defp kind_label(other), do: other

  defp delete_label(true), do: "delete"
  defp delete_label(false), do: "hide"

  defp delete_confirm(true),
    do: "Delete this sent item for every recipient? This cannot be undone."

  defp delete_confirm(false),
    do: "Hide this item from your history? You can request a future message again."
end
