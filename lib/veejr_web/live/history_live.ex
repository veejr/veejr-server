defmodule VeejrWeb.HistoryLive do
  use VeejrWeb, :live_view

  import VeejrWeb.MessagingComponents

  alias Veejr.Messaging

  @filters [
    {"all", "Everything"},
    {"message", "✉️ Messages"},
    {"location", "📍 Locations"},
    {"note", "📝 Notes"}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_count={@pending_count}>
      <.header>
        History
        <:subtitle>
          Everything you've sent or accepted, decrypted only in your browser.
        </:subtitle>
      </.header>

      <div class="mt-4 flex gap-1">
        <.link
          :for={{value, label} <- filters()}
          patch={~p"/history?#{[kind: value]}"}
          class={["btn btn-sm", if(@kind == value, do: "btn-primary", else: "btn-ghost")]}
        >
          {label}
        </.link>
      </div>

      <p :if={@history == []} class="mt-6 text-sm opacity-60">Nothing here yet.</p>

      <ul class="mt-4 space-y-2">
        <.envelope_item
          :for={{envelope, label} <- @history}
          envelope={envelope}
          user={@current_scope.user}
          label={label}
          conversation_path={~p"/messages?conversation=#{envelope.thread_key}"}
        />
      </ul>
    </Layouts.app>
    """
  end

  defp filters, do: @filters

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "History")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = if params["kind"] in ~w(message location note), do: params["kind"], else: "all"
    {:noreply, socket |> assign(kind: kind) |> refresh()}
  end

  @impl true
  def handle_info({:veejr_notification, _}, socket), do: {:noreply, refresh(socket)}

  # Other broadcasts on the user's topic belong to other views; ignoring them
  # here keeps a new message type from crashing this one.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("message_displayed", %{"id" => public_id}, socket) do
    case Messaging.record_display(socket.assigns.current_scope.user, public_id) do
      {:ok, envelope}
      when is_integer(envelope.max_displays) and
             envelope.display_count >= envelope.max_displays ->
        {:reply, %{ok: true}, refresh(socket)}

      _ ->
        {:reply, %{ok: true}, socket}
    end
  end

  defp refresh(socket) do
    user = socket.assigns.current_scope.user

    opts =
      [limit: 200] ++ if(socket.assigns.kind == "all", do: [], else: [kind: socket.assigns.kind])

    history =
      user
      |> Messaging.list_history(opts)
      |> Enum.map(&{&1, history_label(user, &1)})

    assign(socket, history: history)
  end

  defp history_label(user, envelope) do
    if envelope.sender_id == user.id do
      case Messaging.batch_recipients(user, envelope.batch_id) do
        [] -> "To yourself"
        handles -> "To " <> Enum.join(handles, ", ")
      end
    else
      "From #{Veejr.Social.Address.handle(envelope.sender)}"
    end
  end
end
