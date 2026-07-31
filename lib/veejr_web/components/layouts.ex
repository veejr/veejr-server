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

  attr :main_class, :string,
    default: nil,
    doc: "additional classes applied to the main page region"

  attr :main_padding_class, :string,
    default: "py-10",
    doc:
      "vertical padding for the main page region. Pages that fill the viewport " <>
        "instead of scrolling pass \"\" and manage their own spacing"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-svh min-h-svh flex-col">
      <div
        id="connection-status"
        role="status"
        aria-live="polite"
        class="fixed inset-x-0 top-0 z-[100] hidden items-center justify-center gap-2 bg-warning px-4 py-2 text-center text-sm font-medium text-warning-content shadow-lg"
      >
        <.icon name="hero-signal-slash" class="size-4" />
        <span data-role="connection-status-text">Connection interrupted</span>
      </div>
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
            class="app-menu-surface dropdown-content z-50 mt-2 w-72 rounded-2xl border p-2"
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
              <li
                id="primary-navigation-themes"
                class="menu-title mt-2 border-t border-base-300 px-3 py-2 text-xs font-semibold tracking-wider uppercase opacity-55"
              >
                Themes
              </li>
              <li class="px-1 pb-1">
                <.theme_toggle />
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
              <li>
                <.link navigate={~p"/users/log-in"} class="btn btn-primary btn-sm">Log in</.link>
              </li>
            <% end %>
          </ul>
        </div>
      </header>

      <main class={["px-4 sm:px-6 lg:px-8", @main_padding_class, @main_class]}>
        <div class={@container_class}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
    </div>
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
  Labeled theme choices for the hamburger navigation. The options cover the
  Classic family (system-following light/dark) plus the Art Deco theme.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div id="theme-choices" class="grid gap-1.5" aria-label="Theme choices">
      <button
        id="theme-system"
        type="button"
        class="theme-choice"
        phx-click={
          JS.dispatch("phx:set-theme")
          |> JS.remove_attribute("open", to: "#primary-navigation-menu")
        }
        data-phx-theme="system"
        aria-pressed="false"
        title="Match system light or dark"
      >
        <span class="theme-choice-preview">
          <.icon name="hero-computer-desktop-micro" class="size-4" />
        </span>
        <span class="min-w-0 flex-1 text-left">
          <span class="theme-choice-name">System</span>
          <span class="theme-choice-description">Follow this device</span>
        </span>
        <span class="theme-choice-check" aria-hidden="true">
          <.icon name="hero-check-micro" class="size-4" />
        </span>
      </button>

      <button
        id="theme-light"
        type="button"
        class="theme-choice"
        phx-click={
          JS.dispatch("phx:set-theme")
          |> JS.remove_attribute("open", to: "#primary-navigation-menu")
        }
        data-phx-theme="light"
        aria-pressed="false"
        title="Light"
      >
        <span class="theme-choice-preview">
          <.icon name="hero-sun-micro" class="size-4" />
        </span>
        <span class="min-w-0 flex-1 text-left">
          <span class="theme-choice-name">Light</span>
          <span class="theme-choice-description">Bright and neutral</span>
        </span>
        <span class="theme-choice-check" aria-hidden="true">
          <.icon name="hero-check-micro" class="size-4" />
        </span>
      </button>

      <button
        id="theme-dark"
        type="button"
        class="theme-choice"
        phx-click={
          JS.dispatch("phx:set-theme")
          |> JS.remove_attribute("open", to: "#primary-navigation-menu")
        }
        data-phx-theme="dark"
        aria-pressed="false"
        title="Dark"
      >
        <span class="theme-choice-preview">
          <.icon name="hero-moon-micro" class="size-4" />
        </span>
        <span class="min-w-0 flex-1 text-left">
          <span class="theme-choice-name">Dark</span>
          <span class="theme-choice-description">Low-light contrast</span>
        </span>
        <span class="theme-choice-check" aria-hidden="true">
          <.icon name="hero-check-micro" class="size-4" />
        </span>
      </button>

      <button
        id="theme-artdeco"
        type="button"
        class="theme-choice"
        phx-click={
          JS.dispatch("phx:set-theme")
          |> JS.remove_attribute("open", to: "#primary-navigation-menu")
        }
        data-phx-theme="artdeco"
        aria-pressed="false"
        title="Art Deco"
      >
        <span class="theme-choice-preview">
          <.icon name="hero-sparkles-micro" class="size-4" />
        </span>
        <span class="min-w-0 flex-1 text-left">
          <span class="theme-choice-name">Art Deco</span>
          <span class="theme-choice-description">Black, cream and gold</span>
        </span>
        <span class="theme-choice-check" aria-hidden="true">
          <.icon name="hero-check-micro" class="size-4" />
        </span>
      </button>
    </div>
    """
  end
end
