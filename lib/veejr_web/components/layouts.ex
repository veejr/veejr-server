defmodule VeejrWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use VeejrWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The veejr logo mark: a map-pin / teardrop with a keyhole knocked out of it —
  "your private place". Inherits the surrounding text color via `currentColor`,
  so it adapts to every theme. Pass a unique `id` when more than one mark can
  appear on the same page (the keyhole knockout uses an SVG `<mask>`).
  """
  attr :class, :string, default: "size-6"
  attr :id, :string, default: "veejr-mark"
  attr :rest, :global

  def veejr_mark(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 100 128"
      fill="currentColor"
      role="img"
      aria-label="veejr"
      xmlns="http://www.w3.org/2000/svg"
      {@rest}
    >
      <mask id={"#{@id}-cut"}>
        <rect x="0" y="0" width="100" height="128" fill="#fff" />
        <circle cx="50" cy="45" r="15.5" fill="#000" />
        <path d="M42.5 52 L57.5 52 L53.5 80 L46.5 80 Z" fill="#000" />
      </mask>
      <path
        d="M50 3 C24.5 3 5 23 5 47 C5 80 50 122 50 122 C50 122 95 80 95 47 C95 23 75.5 3 50 3 Z"
        mask={"url(##{@id}-cut)"}
      />
    </svg>
    """
  end

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :pending_count, :integer,
    default: nil,
    doc: "number of pending encrypted-item notifications, shown on the Contacts link"

  attr :container_class, :string,
    default: "mx-auto max-w-3xl space-y-4",
    doc: "classes applied to the inner page container"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-40 flex min-h-16 flex-wrap items-center gap-2 border-b border-base-300 bg-base-100/95 px-4 py-2 shadow-sm backdrop-blur sm:flex-nowrap sm:px-6 lg:px-8">
      <details
        :if={@current_scope}
        id="primary-navigation-menu"
        phx-hook=".NavigationMenu"
        class="dropdown shrink-0"
      >
        <summary
          id="primary-navigation-trigger"
          class="btn btn-ghost btn-square btn-sm list-none [&::-webkit-details-marker]:hidden"
          aria-label="Open navigation menu"
          aria-controls="primary-navigation-links"
          title="Menu"
        >
          <.icon name="hero-bars-3" class="size-5" />
        </summary>
        <nav
          id="primary-navigation-links"
          aria-label="Primary navigation"
          class="dropdown-content z-50 mt-2 w-60 rounded-2xl border border-base-300 bg-base-100 p-2 shadow-xl"
        >
          <ul class="menu gap-1 p-0">
            <li class="menu-title px-3 py-2 text-xs font-semibold tracking-wider uppercase opacity-55">
              Navigate
            </li>
            <li>
              <.link
                navigate={~p"/contacts"}
                phx-click={JS.remove_attribute("open", to: "#primary-navigation-menu")}
              >
                <.icon name="hero-user-group" class="size-4" />
                <span class="flex-1">Contacts</span>
                <span
                  :if={@pending_count && @pending_count > 0}
                  class="badge badge-primary badge-sm"
                >
                  {@pending_count}
                </span>
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/messages"}
                phx-click={JS.remove_attribute("open", to: "#primary-navigation-menu")}
              >
                <.icon name="hero-chat-bubble-left-right" class="size-4" /> Messages
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/calls"}
                phx-click={JS.remove_attribute("open", to: "#primary-navigation-menu")}
              >
                <.icon name="hero-video-camera" class="size-4" /> Calls
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/map"}
                phx-click={JS.remove_attribute("open", to: "#primary-navigation-menu")}
              >
                <.icon name="hero-map" class="size-4" /> Map
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/history"}
                phx-click={JS.remove_attribute("open", to: "#primary-navigation-menu")}
              >
                <.icon name="hero-clock" class="size-4" /> History
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/watch"}
                phx-click={JS.remove_attribute("open", to: "#primary-navigation-menu")}
              >
                <.icon name="hero-play-circle" class="size-4" /> Watch
              </.link>
            </li>
          </ul>
        </nav>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".NavigationMenu">
          export default {
            mounted() {
              this.closeOnOutsidePress = event => {
                if (this.el.open && !this.el.contains(event.target)) {
                  this.el.removeAttribute("open")
                }
              }
              this.closeOnEscape = event => {
                if (event.key === "Escape" && this.el.open) {
                  this.el.removeAttribute("open")
                  this.el.querySelector("summary")?.focus()
                }
              }
              document.addEventListener("pointerdown", this.closeOnOutsidePress)
              document.addEventListener("keydown", this.closeOnEscape)
            },
            destroyed() {
              document.removeEventListener("pointerdown", this.closeOnOutsidePress)
              document.removeEventListener("keydown", this.closeOnEscape)
            }
          }
        </script>
      </details>
      <.link
        navigate={~p"/"}
        class="flex items-center gap-2 text-lg font-bold tracking-tight whitespace-nowrap"
      >
        <.veejr_mark class="size-6 veejr-brand" id="header-mark" />
        <span class="lowercase">veejr</span>
      </.link>
      <div class="ml-auto shrink-0">
        <ul class="flex px-1 space-x-2 items-center">
          <li><.theme_toggle /></li>
          <%= if @current_scope do %>
            <li>
              <.link
                navigate={~p"/account"}
                class="btn btn-ghost btn-sm max-w-40 truncate"
                title="Account"
              >
                @{@current_scope.user.username}
              </.link>
            </li>
            <li>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
                Log out
              </.link>
            </li>
          <% else %>
            <li>
              <.link navigate={~p"/users/register"} class="btn btn-ghost btn-sm">Register</.link>
            </li>
            <li><.link navigate={~p"/users/log-in"} class="btn btn-primary btn-sm">Log in</.link></li>
          <% end %>
        </ul>
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class={@container_class}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        auto_dismiss={false}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        auto_dismiss={false}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Theme picker for the themes defined in app.css: the Classic family
  (system-following light/dark, the app's original look) plus the Art Deco
  theme from the design handoff.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/4 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/4 [[data-theme=dark]_&]:left-2/4 [[data-theme=artdeco]_&]:left-3/4 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/4"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="Match system light or dark"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/4"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/4"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/4"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="artdeco"
        title="Art Deco"
      >
        <.icon name="hero-sparkles-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
