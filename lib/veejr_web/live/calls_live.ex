defmodule VeejrWeb.CallsLive do
  use VeejrWeb, :live_view

  alias Veejr.{Calls, Social}
  alias Veejr.Calls.ScheduledCall

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-5xl space-y-6"
    >
      <section class="overflow-hidden rounded-[32px] border border-base-300 bg-base-100 shadow-sm">
        <div class="grid gap-0 lg:grid-cols-[0.92fr_1.08fr]">
          <div class="bg-gradient-to-br from-primary/15 via-base-200 to-secondary/10 p-6 sm:p-8">
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">
              Calls
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Plan time together</h1>
            <p class="mt-3 max-w-md text-sm leading-relaxed opacity-70">
              Schedule a private one-to-one call. Both people see the plan and shared notes,
              with device notifications and email reminders before it starts.
            </p>
            <div class="mt-6 rounded-3xl border border-base-300/80 bg-base-100/75 p-4 backdrop-blur">
              <div class="flex items-start gap-3">
                <div class="flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
                  <.icon name="hero-bell-alert" class="size-5" />
                </div>
                <div>
                  <p class="font-medium">Persistent reminders</p>
                  <p class="mt-1 text-xs leading-relaxed opacity-65">
                    Schedules survive restarts. Notification permission is requested after your
                    first interaction with veejr.
                  </p>
                </div>
              </div>
            </div>
          </div>

          <div class="p-6 sm:p-8">
            <h2 class="text-xl font-semibold">Schedule a call</h2>
            <.form
              for={@schedule_form}
              id="schedule-call-form"
              phx-submit="schedule"
              phx-hook="ScheduleTime"
              class="mt-5 space-y-4"
            >
              <.input
                field={@schedule_form[:friend_id]}
                type="select"
                label="Person"
                prompt="Choose a friend"
                options={Enum.map(@friends, &{Social.Address.handle(&1), &1.id})}
                required
              />
              <.input field={@schedule_form[:scheduled_for]} type="hidden" />
              <.input
                id="scheduled-call-local-time"
                name="scheduled_for_local"
                type="datetime-local"
                label="Date and time"
                value=""
                required
              />
              <.input
                field={@schedule_form[:reminder_minutes]}
                type="select"
                label="Remind me"
                options={reminder_options()}
              />
              <.input
                field={@schedule_form[:note]}
                type="textarea"
                label="Call notes (optional)"
                maxlength="500"
                rows="3"
                placeholder="What would you like to talk about?"
              />
              <button
                id="schedule-call-submit"
                type="submit"
                class="btn btn-primary w-full rounded-2xl"
              >
                <.icon name="hero-calendar-days" class="size-4" /> Schedule call
              </button>
            </.form>
          </div>
        </div>
      </section>

      <section id="scheduled-calls" class="space-y-3">
        <div class="flex items-end justify-between gap-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-primary">
              Your calendar
            </p>
            <h2 class="mt-1 text-2xl font-semibold tracking-tight">Scheduled calls</h2>
          </div>
          <span class="badge badge-outline">{length(@schedules)}</span>
        </div>

        <div
          :if={@schedules == []}
          id="scheduled-calls-empty"
          class="rounded-3xl border border-dashed border-base-300 bg-base-100 p-8 text-center"
        >
          <.icon name="hero-calendar-days" class="mx-auto size-8 opacity-35" />
          <p class="mt-3 font-medium">Nothing scheduled yet</p>
          <p class="mt-1 text-sm opacity-60">Choose a friend and a time above.</p>
        </div>

        <details
          :for={schedule <- @schedules}
          id={"scheduled-call-#{schedule.id}"}
          phx-hook=".ScheduledCallCard"
          class="group overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm transition-shadow open:shadow-md"
        >
          <summary
            id={"scheduled-call-summary-#{schedule.id}"}
            class="flex cursor-pointer list-none items-center gap-3 px-4 py-3 transition-colors select-none hover:bg-base-200/60 focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-primary [&::-webkit-details-marker]:hidden"
          >
            <span class="min-w-0 flex-1 truncate font-semibold">
              {Social.Address.handle(peer(schedule, @current_scope.user))}
            </span>
            <time
              id={"scheduled-call-time-#{schedule.id}"}
              phx-hook="LocalTime"
              datetime={DateTime.to_iso8601(schedule.scheduled_for)}
              class="shrink-0 whitespace-nowrap text-xs font-medium text-primary sm:text-sm"
            >
              {Calendar.strftime(schedule.scheduled_for, "%b %d, %Y %H:%M UTC")}
            </time>
            <.icon
              name="hero-chevron-down"
              class="size-4 shrink-0 opacity-55 transition-transform group-open:rotate-180"
            />
          </summary>
          <div class="border-t border-base-300 p-5">
            <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <div class="flex min-w-0 items-center gap-4">
                <.user_avatar
                  user={peer(schedule, @current_scope.user)}
                  class="size-12 text-sm"
                />
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="truncate text-lg font-semibold">
                      {Social.Address.handle(peer(schedule, @current_scope.user))}
                    </h3>
                    <span class={status_class(schedule.status)}>{status_label(schedule.status)}</span>
                  </div>
                  <p class="mt-1 text-xs opacity-60">
                    Reminder {reminder_label(schedule.reminder_minutes)}
                    <span :if={schedule.organizer_id != @current_scope.user.id}>
                      · organized by {Social.Address.handle(schedule.organizer)}
                    </span>
                  </p>
                </div>
              </div>

              <div :if={schedule.status == "scheduled"} class="flex shrink-0 flex-wrap gap-2">
                <button
                  :if={schedule.organizer_id == @current_scope.user.id}
                  id={"start-scheduled-call-#{schedule.id}"}
                  phx-click="start"
                  phx-value-id={schedule.id}
                  phx-disable-with="Starting…"
                  class="btn btn-primary btn-sm rounded-xl"
                >
                  <.icon name="hero-phone" class="size-4" /> Start now
                </button>
                <button
                  :if={schedule.organizer_id == @current_scope.user.id}
                  id={"cancel-scheduled-call-#{schedule.id}"}
                  phx-click="cancel"
                  phx-value-id={schedule.id}
                  data-confirm="Cancel this scheduled call for both people?"
                  class="btn btn-ghost btn-sm rounded-xl text-error"
                >
                  Cancel
                </button>
                <span
                  :if={schedule.organizer_id != @current_scope.user.id}
                  class="rounded-xl bg-base-200 px-3 py-2 text-xs opacity-65"
                >
                  Waiting for organizer
                </span>
              </div>
            </div>

            <.form
              for={@note_forms[schedule.id]}
              id={"scheduled-call-note-form-#{schedule.id}"}
              phx-submit="save_note"
              class="mt-4 rounded-2xl border border-base-300 bg-base-200/60 p-4"
            >
              <input type="hidden" name="_id" value={schedule.id} />
              <.input
                field={@note_forms[schedule.id][:note]}
                type="textarea"
                label="Call notes"
                maxlength="500"
                rows="3"
                disabled={schedule.organizer_id != @current_scope.user.id}
                placeholder="Topics, links, or anything to remember for this call"
              />
              <div class="mt-2 flex items-center justify-between gap-3">
                <p class="text-xs opacity-60">
                  <%= if schedule.organizer_id == @current_scope.user.id do %>
                    Shared with the invitee.
                  <% else %>
                    Shared by {Social.Address.handle(schedule.organizer)}.
                  <% end %>
                </p>
                <button
                  :if={schedule.organizer_id == @current_scope.user.id}
                  id={"save-scheduled-call-note-#{schedule.id}"}
                  type="submit"
                  class="btn btn-outline btn-sm rounded-xl"
                >
                  Save notes
                </button>
              </div>
            </.form>
          </div>
        </details>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ScheduledCallCard">
          export default {
            beforeUpdate() {
              this.wasOpen = this.el.open
            },
            updated() {
              if (typeof this.wasOpen === "boolean") this.el.open = this.wasOpen
            }
          }
        </script>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_scope.user
    friends = Social.list_friends(user)
    selected_friend_id = selected_friend_id(params["friend_id"], friends)

    {:ok,
     socket
     |> assign(
       page_title: "Calls",
       friends: friends,
       schedule_form: schedule_form(selected_friend_id)
     )
     |> assign_schedules(user)}
  end

  @impl true
  def handle_event("schedule", %{"schedule" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Calls.schedule_call(user, params["friend_id"], params) do
      {:ok, _schedule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Call scheduled. Both people will receive a reminder.")
         |> assign(schedule_form: schedule_form(params["friend_id"]))
         |> assign_schedules(user)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, changeset_error(changeset))
         |> assign(schedule_form: to_form(params, as: :schedule))}

      {:error, :peer_blocked} ->
        {:noreply, put_flash(socket, :error, "That federated instance is blocked.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The call could not be scheduled.")}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Calls.cancel_scheduled_call(user, parse_id(id)) do
      {:ok, _schedule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Scheduled call cancelled.")
         |> assign_schedules(user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The scheduled call could not be cancelled.")}
    end
  end

  def handle_event("start", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Calls.start_scheduled_call(user, parse_id(id)) do
      {:ok, call} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/call/#{call.public_id}?#{[return_to: ~p"/calls"]}"
         )}

      {:error, :callee_unreachable} ->
        {:noreply, put_flash(socket, :error, "Their instance is unreachable right now.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The scheduled call could not be started.")}
    end
  end

  def handle_event("save_note", %{"_id" => id, "schedule_note" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Calls.update_scheduled_call_note(user, parse_id(id), params) do
      {:ok, _schedule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Call notes saved.")
         |> assign_schedules(user)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Only the organizer can change call notes.")}
    end
  end

  @impl true
  def handle_info({:veejr_call_schedule, _event, _schedule, _peer}, socket) do
    {:noreply, assign_schedules(socket, socket.assigns.current_scope.user)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp schedule_form(friend_id) do
    to_form(
      %{
        "friend_id" => to_string(friend_id || ""),
        "scheduled_for" =>
          DateTime.utc_now(:second) |> DateTime.add(30, :minute) |> DateTime.to_iso8601(),
        "reminder_minutes" => "15",
        "note" => ""
      },
      as: :schedule
    )
  end

  defp assign_schedules(socket, user) do
    schedules = Calls.list_scheduled_calls(user)

    note_forms =
      Map.new(schedules, fn schedule ->
        {schedule.id, to_form(%{"note" => schedule.note || ""}, as: :schedule_note)}
      end)

    assign(socket, schedules: schedules, note_forms: note_forms)
  end

  defp selected_friend_id(nil, _friends), do: nil

  defp selected_friend_id(id, friends) do
    case Integer.parse(id) do
      {parsed, ""} -> if(Enum.any?(friends, &(&1.id == parsed)), do: parsed, else: nil)
      _ -> nil
    end
  end

  defp parse_id(id) do
    case Integer.parse(to_string(id)) do
      {parsed, ""} -> parsed
      _ -> -1
    end
  end

  defp peer(schedule, user) do
    if schedule.organizer_id == user.id, do: schedule.invitee, else: schedule.organizer
  end

  defp reminder_options do
    Enum.map(ScheduledCall.reminder_minutes(), &{reminder_label(&1), &1})
  end

  defp reminder_label(1_440), do: "1 day before"
  defp reminder_label(60), do: "1 hour before"
  defp reminder_label(minutes), do: "#{minutes} minutes before"

  defp status_label("scheduled"), do: "Scheduled"
  defp status_label("cancelled"), do: "Cancelled"
  defp status_label("started"), do: "Started"

  defp status_class("scheduled"), do: "badge badge-primary badge-sm"
  defp status_class("cancelled"), do: "badge badge-ghost badge-sm opacity-60"
  defp status_class("started"), do: "badge badge-success badge-sm"

  defp changeset_error(changeset) do
    case changeset.errors do
      [{_field, {message, _opts}} | _] -> "The scheduled call #{message}."
      _ -> "Check the date, reminder, and selected friend."
    end
  end
end
