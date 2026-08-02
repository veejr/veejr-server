defmodule VeejrWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: VeejrWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :user, :any, required: true
  attr :class, :any, default: "size-10"
  attr :ring, :boolean, default: true
  attr :on_click, :string, default: nil
  attr :rest, :global

  @doc "Renders a user's uploaded avatar or a stable, colorful initials placeholder."
  def user_avatar(assigns) do
    assigns =
      assigns
      |> assign(:url, Veejr.Accounts.avatar_url(assigns.user))
      |> assign(:label, avatar_label(assigns.user))
      |> assign(:initials, avatar_initials(assigns.user))
      |> assign(:palette, avatar_palette(assigns.user))

    ~H"""
    <button
      :if={@on_click}
      type="button"
      phx-click={@on_click}
      phx-value-id={@user.id}
      title={"Open #{@user.display_name || @user.username || "profile"} profile"}
      class={[
        "relative inline-flex shrink-0 overflow-hidden rounded-full transition hover:scale-105 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
        @ring && "ring-2 ring-base-100 shadow-sm",
        @class
      ]}
      {@rest}
    >
      <img
        :if={@url}
        src={@url}
        alt={@label}
        loading="lazy"
        draggable="false"
        class="size-full object-cover"
      />
      <span
        :if={!@url}
        role="img"
        aria-label={@label}
        class={[
          "flex size-full items-center justify-center font-semibold uppercase",
          @palette
        ]}
      >
        {@initials}
      </span>
    </button>
    <span
      :if={!@on_click}
      class={[
        "relative inline-flex shrink-0 overflow-hidden rounded-full",
        @ring && "ring-2 ring-base-100 shadow-sm",
        @class
      ]}
      {@rest}
    >
      <img
        :if={@url}
        src={@url}
        alt={@label}
        loading="lazy"
        draggable="false"
        class="size-full object-cover"
      />
      <span
        :if={!@url}
        role="img"
        aria-label={@label}
        class={[
          "flex size-full items-center justify-center font-semibold uppercase",
          @palette
        ]}
      >
        {@initials}
      </span>
    </span>
    """
  end

  attr :state, :atom, required: true, values: [:online, :recently, :offline, :unknown]
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  @doc """
  Renders a contact's presence as a dot beside their avatar.

  Place inside a `relative` wrapper alongside `user_avatar/1`.

  Nothing is drawn for `:unknown` — a contact on another instance, or one who
  turned sharing off, gives us no basis for a claim, and an absent dot says
  that without pretending they are offline. The other three states are all
  positively known for a local contact who shares, so all three are drawn.
  """
  def presence_dot(assigns) do
    ~H"""
    <span
      :if={@state != :unknown}
      id={@id}
      data-presence={@state}
      title={Veejr.Presence.label(@state)}
      class={[
        "pointer-events-none absolute -right-0.5 -bottom-0.5 size-3 rounded-full ring-2 ring-base-100 transition-colors",
        @state == :online && "bg-success",
        @state == :recently && "bg-warning/70",
        @state == :offline && "bg-base-300",
        @class
      ]}
    >
      <span class="sr-only">{Veejr.Presence.label(@state)}</span>
    </span>
    """
  end

  attr :showing, :string, required: true, doc: "the layout the calling page renders"
  attr :id, :string, default: "page-layout-switch"
  attr :class, :any, default: nil

  @doc """
  Chooses between the full Contacts and Messages pages and the plain pair.

  The choice is saved on the account, so it is a preference rather than a
  detour: picking Simple here is what makes `/contacts` and `/messages` open
  the plain pages next time.
  """
  def page_layout_switch(assigns) do
    ~H"""
    <div
      id={@id}
      role="group"
      aria-label="Page layout"
      class={[
        "inline-flex items-center gap-1 rounded-xl border border-base-300 bg-base-200 p-1 text-xs font-semibold",
        @class
      ]}
    >
      <span class="px-2 text-base-content/55">Layout</span>
      <button
        :for={{value, label} <- [{"full", "Full"}, {"simple", "Simple"}]}
        id={"#{@id}-#{value}"}
        type="button"
        phx-click="set_page_layout"
        phx-value-layout={value}
        aria-pressed={to_string(@showing == value)}
        class={[
          "rounded-lg px-2.5 py-1.5 transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
          @showing == value && "bg-base-100 text-base-content shadow-sm",
          @showing != value && "text-base-content/60 hover:text-base-content"
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :id, :string, required: true, doc: "prefix for this player's assist controls"

  @doc """
  The way out when YouTube stops a viewer with its bot check.

  A synchronized viewer does not steer the video, so the player sits behind a
  click guard — and that guard is exactly what traps someone YouTube has
  decided to challenge. The check is answered by a signed-in YouTube session in
  the frame that shows it, which `youtube-nocookie.com` can never carry, so
  this panel offers the two places the viewer can actually answer it: the same
  video reloaded from `youtube.com`, or YouTube itself in another tab. Showing
  the panel also releases the guard, because a prompt nobody can click is not a
  prompt.

  The browser hook owns the visibility, the link target, and the reload; the
  markup is here so all three players offer the same way out.
  """
  def youtube_playback_assist(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="youtube-assist"
      class="pointer-events-none absolute inset-0 z-40 hidden items-end justify-center p-3 sm:p-4"
    >
      <div class="pointer-events-auto w-full max-w-md rounded-2xl border border-base-300 bg-base-100/95 p-4 text-base-content shadow-2xl backdrop-blur">
        <div class="flex items-start gap-3">
          <span class="grid size-9 shrink-0 place-items-center rounded-xl bg-warning/15 text-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
          </span>
          <div class="min-w-0">
            <p class="font-semibold">This video is not playing here</p>
            <p class="mt-1 text-sm leading-6 opacity-70">
              YouTube sometimes asks a viewer to sign in and confirm they are not a bot.
              The private player cannot see your YouTube account, so answer the check in
              one of these two places — playback rejoins the group on its own afterwards.
            </p>
          </div>
        </div>
        <div class="mt-3 flex flex-wrap gap-2">
          <button
            id={"#{@id}-signed-in"}
            type="button"
            data-role="youtube-signed-in"
            class="btn btn-primary btn-sm rounded-xl"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Reload with sign-in
          </button>
          <a
            id={"#{@id}-open"}
            data-role="youtube-open"
            href="https://www.youtube.com"
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-outline btn-sm rounded-xl"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open on YouTube
          </a>
          <button
            id={"#{@id}-dismiss"}
            type="button"
            data-role="youtube-assist-dismiss"
            class="btn btn-ghost btn-sm rounded-xl"
          >
            Dismiss
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true, doc: "id for the help button"
  attr :label, :string, required: true, doc: "who is steering this video"
  attr :label_role, :string, default: nil, doc: "data-role the hook rewrites the label through"

  @doc """
  Names whoever steers a shared video and keeps the assist panel one tap away.

  The detector in the hook only sees playback that never starts. YouTube can
  interrupt a viewer in ways that never reach it, so the way out is always
  reachable by hand rather than only when we notice.
  """
  def youtube_viewer_bar(assigns) do
    ~H"""
    <div class="pointer-events-none absolute inset-x-3 top-3 z-30 flex items-start justify-between gap-2 sm:inset-x-4 sm:top-4">
      <span
        data-role={@label_role}
        class="rounded-full bg-black/75 px-3 py-1.5 text-xs font-semibold text-white shadow-lg backdrop-blur"
      >
        {@label}
      </span>
      <button
        id={@id}
        type="button"
        data-role="youtube-help"
        class="pointer-events-auto rounded-full bg-black/75 px-3 py-1.5 text-xs font-semibold text-white shadow-lg backdrop-blur transition hover:bg-black/90"
      >
        Not playing?
      </button>
    </div>
    """
  end

  attr :user, :any, default: nil
  attr :note, :string, default: ""
  attr :editable, :boolean, default: false
  attr :close_event, :string, default: "close_profile"
  attr :save_event, :string, default: "save_profile_note"

  @doc "Renders an enlarged profile image and the viewer's private contact note."
  def profile_dialog(assigns) do
    ~H"""
    <div
      :if={@user}
      id="profile-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="profile-dialog-title"
      phx-window-keydown={@close_event}
      phx-key="Escape"
      class="fixed inset-0 z-[1000] flex items-center justify-center bg-black/65 p-4"
    >
      <section
        phx-click-away={@close_event}
        class="relative max-h-[92svh] w-full max-w-lg overflow-y-auto rounded-lg bg-base-100 p-5 text-base-content shadow-2xl sm:p-7"
      >
        <button
          type="button"
          phx-click={@close_event}
          title="Close profile"
          aria-label="Close profile"
          class="absolute right-3 top-3 flex size-9 items-center justify-center rounded-full hover:bg-base-200"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>

        <div class="flex flex-col items-center text-center">
          <.user_avatar user={@user} class="size-48 text-5xl sm:size-56" ring={false} />
          <h2 id="profile-dialog-title" class="mt-5 text-xl font-semibold">
            {@user.display_name || @user.username}
          </h2>
          <p class="mt-1 text-sm opacity-65">{Veejr.Social.Address.handle(@user)}</p>
        </div>

        <form :if={@editable} phx-submit={@save_event} class="mt-6">
          <input type="hidden" name="contact_id" value={@user.id} />
          <label for="profile-note" class="text-sm font-semibold">Personal notes</label>
          <textarea
            id="profile-note"
            name="body"
            rows="5"
            maxlength="4000"
            class="textarea textarea-bordered mt-2 w-full resize-y"
            placeholder="Private notes about this contact"
          >{@note}</textarea>
          <div class="mt-3 flex justify-end">
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-check" class="size-4" /> Save note
            </button>
          </div>
        </form>
      </section>
    </div>
    """
  end

  defp avatar_label(user), do: "#{user.display_name || user.username || "User"} profile image"

  defp avatar_initials(user) do
    (user.display_name || user.username || "?")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &(&1 |> String.first() |> String.upcase()))
  end

  defp avatar_palette(user) do
    palettes = [
      "bg-secondary/20 text-secondary",
      "bg-info/20 text-info",
      "bg-success/20 text-success",
      "bg-warning/25 text-warning-content",
      "bg-error/15 text-error"
    ]

    Enum.at(palettes, :erlang.phash2({user.username, user.host}, length(palettes)))
  end

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :auto_dismiss, :boolean, default: true
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-hook={if(@auto_dismiss, do: "AutoDismissFlash")}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      data-auto-dismiss-ms="1000"
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "password"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
      </label>
      <div id={"#{@id}-password-visibility"} class="relative" phx-hook="PasswordVisibility">
        <input
          type="password"
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            "w-full !pr-12",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
        <button
          id={"#{@id}-password-visibility-toggle"}
          type="button"
          class="absolute right-1 top-1/2 z-10 flex size-10 -translate-y-1/2 items-center justify-center rounded-md text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          data-role="password-visibility-toggle"
          data-secret-label="password"
          aria-label="Show password"
          aria-pressed="false"
        >
          <span data-role="password-visibility-icon">
            <.icon name="hero-eye" class="size-5" />
          </span>
        </button>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(VeejrWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(VeejrWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
