defmodule VeejrWeb.SimpleDemoLive do
  @moduledoc """
  A public, self-contained tour of the simple contacts and messages experience.

  The demo deliberately uses sample data and keeps all interaction in the
  LiveView process. It never reads from or writes to a visitor's account.
  """
  use VeejrWeb, :live_view

  @contacts [
    %{
      id: "maya",
      name: "Maya Chen",
      handle: "@maya",
      initials: "MC",
      state: :online,
      color: "from-rose-400 to-orange-300"
    },
    %{
      id: "jules",
      name: "Jules Martin",
      handle: "@jules",
      initials: "JM",
      state: :online,
      color: "from-violet-500 to-indigo-400"
    },
    %{
      id: "dev",
      name: "Dev Patel",
      handle: "@dev",
      initials: "DP",
      state: :away,
      color: "from-sky-400 to-cyan-300"
    },
    %{
      id: "nora",
      name: "Nora Kim",
      handle: "@nora",
      initials: "NK",
      state: :offline,
      color: "from-emerald-500 to-teal-300"
    },
    %{
      id: "leo",
      name: "Leo Silva",
      handle: "@leo",
      initials: "LS",
      state: :online,
      color: "from-amber-400 to-yellow-300"
    },
    %{
      id: "sana",
      name: "Sana Okafor",
      handle: "@sana",
      initials: "SO",
      state: :away,
      color: "from-fuchsia-500 to-pink-400"
    }
  ]

  @sample_messages %{
    "maya" => [
      %{
        id: "maya-1",
        mine?: false,
        body: "The train just pulled in — I’ll be there in ten.",
        time: "10:24"
      },
      %{
        id: "maya-2",
        mine?: true,
        body: "Perfect. I found us a quiet table by the window.",
        time: "10:25"
      },
      %{id: "maya-3", mine?: false, body: "Lovely. See you soon ✨", time: "10:26"}
    ],
    "jules" => [
      %{
        id: "jules-1",
        mine?: false,
        body: "Want to review the sketches this afternoon?",
        time: "Yesterday"
      },
      %{id: "jules-2", mine?: true, body: "Yes — 3pm works for me.", time: "Yesterday"}
    ],
    "dev" => [
      %{
        id: "dev-1",
        mine?: false,
        body: "That recipe was a hit. Sending you my notes later!",
        time: "Mon"
      }
    ],
    "nora" => [],
    "leo" => [
      %{id: "leo-1", mine?: true, body: "Safe travels — message me when you land.", time: "Fri"},
      %{id: "leo-2", mine?: false, body: "Landed! Everything went smoothly.", time: "Fri"}
    ],
    "sana" => [
      %{id: "sana-1", mine?: false, body: "Coffee walk tomorrow morning?", time: "Thu"}
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Simple view demo",
       screen: :contacts,
       selected_contact: nil,
       call_contact: nil,
       contacts: @contacts,
       messages: @sample_messages,
       search_form: to_form(%{"query" => ""}, as: :search),
       message_form: to_form(%{"body" => ""}, as: :message)
     )
     |> stream_configure(:demo_contacts, dom_id: &"demo-contact-#{&1.id}")
     |> stream(:demo_contacts, @contacts)
     |> stream_configure(:demo_messages, dom_id: &"demo-message-#{&1.id}")
     |> stream(:demo_messages, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      main_class="flex min-h-0 flex-1 flex-col bg-base-200/35"
      main_padding_class="py-6 sm:py-10"
      container_class="mx-auto flex min-h-0 w-full max-w-5xl flex-1 flex-col px-0"
    >
      <div id="simple-demo" class="flex min-h-0 flex-1 flex-col gap-5">
        <header class="flex flex-col gap-3 px-1 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <div class="mb-2 flex items-center gap-2">
              <span class="inline-flex items-center gap-1.5 rounded-full bg-primary/10 px-2.5 py-1 text-xs font-semibold text-primary ring-1 ring-primary/20">
                <span class="size-1.5 rounded-full bg-primary motion-safe:animate-pulse"></span>
                Interactive demo
              </span>
              <span class="text-xs text-base-content/45">Sample data only</span>
            </div>
            <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Simple, by design.</h1>
            <p class="mt-1 max-w-xl text-sm leading-6 text-base-content/60 sm:text-base">
              Pick a person, read the conversation, and reply. Everything else stays out of the way.
            </p>
          </div>
          <button
            id="demo-reset"
            type="button"
            phx-click="reset_demo"
            class="btn btn-ghost btn-sm self-start rounded-full sm:self-auto"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Start over
          </button>
        </header>

        <section class="relative flex min-h-[36rem] flex-1 overflow-hidden rounded-[2rem] border border-base-300 bg-base-100 shadow-xl shadow-base-content/5">
          <div class="pointer-events-none absolute inset-x-0 top-0 h-32 bg-gradient-to-b from-primary/5 to-transparent">
          </div>

          <div
            :if={@screen == :contacts}
            id="demo-contacts-screen"
            class="relative flex w-full flex-col p-5 sm:p-8"
          >
            <div class="flex items-center justify-between gap-4">
              <div>
                <p class="text-xs font-semibold tracking-[0.16em] text-primary uppercase">
                  Your people
                </p>
                <h2 class="mt-1 text-2xl font-bold tracking-tight">Who do you want to talk to?</h2>
              </div>
              <span class="hidden size-11 items-center justify-center rounded-2xl bg-base-200 text-base-content/60 sm:flex">
                <.icon name="hero-user-group" class="size-5" />
              </span>
            </div>

            <.form
              for={@search_form}
              id="demo-search-form"
              phx-change="filter_contacts"
              class="mt-6 max-w-md"
            >
              <.input
                field={@search_form[:query]}
                type="search"
                label="Find a contact"
                placeholder="Search by name or handle"
                autocomplete="off"
                phx-debounce="150"
              />
            </.form>

            <div
              id="demo-contacts"
              phx-update="stream"
              class="mt-7 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4"
            >
              <div
                id="demo-contacts-empty"
                class="col-span-full hidden rounded-3xl border border-dashed border-base-300 py-14 text-center only:block"
              >
                <span class="mx-auto flex size-11 items-center justify-center rounded-2xl bg-base-200 text-base-content/50">
                  <.icon name="hero-magnifying-glass" class="size-5" />
                </span>
                <p class="mt-3 text-sm font-medium">No one matches that search.</p>
              </div>
              <button
                :for={{dom_id, contact} <- @streams.demo_contacts}
                id={dom_id}
                type="button"
                phx-click="open_conversation"
                phx-value-id={contact.id}
                class="group relative flex min-w-0 flex-col items-center rounded-3xl border border-transparent p-4 text-center transition duration-200 hover:-translate-y-0.5 hover:border-base-300 hover:bg-base-200/60 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
              >
                <span class="relative inline-flex">
                  <span class={[
                    "flex size-20 items-center justify-center rounded-full bg-gradient-to-br text-lg font-bold text-white shadow-lg ring-4 ring-base-100 transition duration-200 group-hover:scale-105",
                    contact.color
                  ]}>
                    {contact.initials}
                  </span>
                  <span class={[
                    "absolute right-0 bottom-0 size-5 rounded-full border-[3px] border-base-100",
                    presence_class(contact.state)
                  ]}></span>
                </span>
                <span class="mt-3 w-full truncate text-sm font-semibold">{contact.name}</span>
                <span class="mt-0.5 w-full truncate text-xs text-base-content/45">{contact.handle}</span>
                <span class="mt-3 inline-flex items-center gap-1 text-xs font-semibold text-primary opacity-0 transition group-hover:opacity-100 group-focus-visible:opacity-100">
                  Message <.icon name="hero-arrow-right-mini" class="size-3.5" />
                </span>
              </button>
            </div>
          </div>

          <div
            :if={@screen == :conversation}
            id="demo-conversation-screen"
            class="relative flex min-h-0 w-full flex-col"
          >
            <header class="flex items-center gap-3 border-b border-base-300 bg-base-100/90 px-4 py-3 backdrop-blur sm:px-6">
              <button
                id="demo-back"
                type="button"
                phx-click="show_contacts"
                aria-label="Back to contacts"
                class="flex size-10 shrink-0 items-center justify-center rounded-full transition hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
              >
                <.icon name="hero-arrow-left" class="size-5" />
              </button>
              <span class={[
                "relative flex size-11 shrink-0 items-center justify-center rounded-full bg-gradient-to-br text-sm font-bold text-white shadow-sm",
                @selected_contact.color
              ]}>
                {@selected_contact.initials}
                <span class={[
                  "absolute right-0 bottom-0 size-3.5 rounded-full border-2 border-base-100",
                  presence_class(@selected_contact.state)
                ]}></span>
              </span>
              <div class="min-w-0 flex-1">
                <h2 class="truncate font-semibold">{@selected_contact.name}</h2>
                <p class="text-xs text-base-content/50">{presence_label(@selected_contact.state)}</p>
              </div>
              <button
                id="demo-call"
                type="button"
                phx-click="open_call"
                aria-label={"Call #{@selected_contact.name}"}
                aria-haspopup="dialog"
                aria-controls="demo-call-dialog"
                class="flex size-10 items-center justify-center rounded-full bg-primary/10 text-primary transition hover:scale-105 hover:bg-primary/15 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
              >
                <.icon name="hero-phone" class="size-4.5" />
              </button>
            </header>

            <div
              id="demo-messages"
              phx-update="stream"
              class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto bg-base-200/25 px-4 py-6 sm:px-8"
            >
              <div id="demo-messages-empty" class="my-auto hidden text-center only:block">
                <span class="mx-auto flex size-14 items-center justify-center rounded-3xl bg-primary/10 text-primary">
                  <.icon name="hero-chat-bubble-left-right" class="size-6" />
                </span>
                <p class="mt-3 font-semibold">A fresh conversation</p>
                <p class="mt-1 text-sm text-base-content/50">Say hello below.</p>
              </div>
              <div
                :for={{dom_id, message} <- @streams.demo_messages}
                id={dom_id}
                data-message-mine={to_string(message.mine?)}
                class={["flex", if(message.mine?, do: "justify-end", else: "justify-start")]}
              >
                <div class={[
                  "max-w-[82%] rounded-3xl px-4 py-3 shadow-sm sm:max-w-[68%]",
                  if(message.mine?,
                    do: "rounded-br-lg bg-primary text-primary-content",
                    else: "rounded-bl-lg border border-base-300 bg-base-100"
                  )
                ]}>
                  <p class="text-[0.95rem] leading-relaxed">{message.body}</p>
                  <p class={[
                    "mt-1 text-right text-[0.65rem]",
                    if(message.mine?, do: "text-primary-content/65", else: "text-base-content/40")
                  ]}>
                    {message.time}
                  </p>
                </div>
              </div>
            </div>

            <div class="border-t border-base-300 bg-base-100 p-3 sm:p-4">
              <.form
                for={@message_form}
                id="demo-message-form"
                phx-submit="send_message"
                class="flex items-end gap-2"
              >
                <div class="min-w-0 flex-1">
                  <.input
                    field={@message_form[:body]}
                    type="text"
                    label="Message"
                    placeholder={"Message #{@selected_contact.name}"}
                    autocomplete="off"
                    phx-hook=".DemoMessageInput"
                    phx-update="ignore"
                  />
                </div>
                <button
                  id="demo-send"
                  type="submit"
                  aria-label="Send message"
                  class="btn btn-primary btn-circle mb-0.5 shrink-0 shadow-md shadow-primary/20"
                >
                  <.icon name="hero-paper-airplane" class="size-4.5" />
                </button>
              </.form>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".DemoMessageInput">
                export default {
                  mounted() {
                    this.handleEvent("demo_message_sent", () => {
                      this.el.value = ""
                      this.el.focus()
                    })
                  }
                }
              </script>
              <p class="mt-2 text-center text-[0.68rem] text-base-content/35">
                Demo messages stay in this browser session and are never sent.
              </p>
            </div>
          </div>
        </section>
      </div>

      <div
        :if={@call_contact}
        id="demo-call-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="demo-call-title"
        phx-mounted={JS.focus(to: "#demo-call-now")}
        phx-window-keydown="close_call"
        phx-key="Escape"
        class="fixed inset-0 z-50 flex items-end justify-center bg-base-content/40 p-4 backdrop-blur-sm sm:items-center"
      >
        <section
          phx-click-away="close_call"
          class="w-full max-w-sm overflow-hidden rounded-[2rem] border border-base-300 bg-base-100 shadow-2xl"
        >
          <div class="bg-gradient-to-br from-primary/15 via-base-100 to-secondary/10 p-7 text-center">
            <span class={[
              "mx-auto flex size-20 items-center justify-center rounded-full bg-gradient-to-br text-lg font-bold text-white shadow-lg ring-4 ring-base-100",
              @call_contact.color
            ]}>
              {@call_contact.initials}
            </span>
            <h2 id="demo-call-title" class="mt-4 text-xl font-bold">Call {@call_contact.name}?</h2>
            <p class="mt-1 text-sm leading-6 text-base-content/55">
              Try the call flow without ringing anyone.
            </p>
          </div>
          <div class="grid gap-2 p-4">
            <button
              id="demo-call-now"
              type="button"
              phx-click="simulate_call"
              class="btn btn-primary h-auto rounded-2xl py-3"
            >
              <.icon name="hero-phone" class="size-4" /> Start demo call
            </button>
            <button
              id="demo-call-cancel"
              type="button"
              phx-click="close_call"
              class="btn btn-ghost rounded-2xl"
            >Not now</button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("filter_contacts", %{"search" => %{"query" => query}}, socket) do
    normalized = query |> String.trim() |> String.downcase()

    contacts =
      Enum.filter(socket.assigns.contacts, fn contact ->
        normalized == "" or
          String.contains?(String.downcase(contact.name), normalized) or
          String.contains?(String.downcase(contact.handle), normalized)
      end)

    {:noreply,
     socket
     |> assign(:search_form, to_form(%{"query" => query}, as: :search))
     |> stream(:demo_contacts, contacts, reset: true)}
  end

  def handle_event("open_conversation", %{"id" => id}, socket) do
    case find_contact(socket.assigns.contacts, id) do
      nil ->
        {:noreply, socket}

      contact ->
        messages = Map.fetch!(socket.assigns.messages, contact.id)

        {:noreply,
         socket
         |> assign(screen: :conversation, selected_contact: contact)
         |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
         |> stream(:demo_messages, messages, reset: true)}
    end
  end

  def handle_event("show_contacts", _params, socket) do
    {:noreply,
     socket
     |> assign(screen: :contacts, selected_contact: nil, call_contact: nil)
     |> stream(:demo_contacts, socket.assigns.contacts, reset: true)}
  end

  def handle_event("send_message", %{"message" => %{"body" => body}}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      contact = socket.assigns.selected_contact

      message = %{
        id: System.unique_integer([:positive]),
        mine?: true,
        body: body,
        time: "Just now"
      }

      updated = Map.update!(socket.assigns.messages, contact.id, &(&1 ++ [message]))

      {:noreply,
       socket
       |> assign(:messages, updated)
       |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
       |> stream_insert(:demo_messages, message)
       |> push_event("demo_message_sent", %{})}
    end
  end

  def handle_event("open_call", _params, socket) do
    {:noreply, assign(socket, :call_contact, socket.assigns.selected_contact)}
  end

  def handle_event("close_call", _params, socket) do
    {:noreply, assign(socket, :call_contact, nil)}
  end

  def handle_event("simulate_call", _params, socket) do
    {:noreply,
     socket
     |> assign(:call_contact, nil)
     |> put_flash(:info, "Demo call started — in the real view, this opens a private call.")}
  end

  def handle_event("reset_demo", _params, socket) do
    {:noreply,
     socket
     |> assign(
       screen: :contacts,
       selected_contact: nil,
       call_contact: nil,
       messages: @sample_messages,
       search_form: to_form(%{"query" => ""}, as: :search),
       message_form: to_form(%{"body" => ""}, as: :message)
     )
     |> stream(:demo_contacts, socket.assigns.contacts, reset: true)
     |> stream(:demo_messages, [], reset: true)}
  end

  defp find_contact(contacts, id), do: Enum.find(contacts, &(&1.id == id))

  defp presence_class(:online), do: "bg-success"
  defp presence_class(:away), do: "bg-warning"
  defp presence_class(:offline), do: "bg-base-300"

  defp presence_label(:online), do: "Online now"
  defp presence_label(:away), do: "Away"
  defp presence_label(:offline), do: "Offline"
end
