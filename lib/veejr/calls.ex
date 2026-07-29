defmodule Veejr.Calls do
  @moduledoc """
  Synchronous 1:1 audio/video calls.

  The server never touches call media: WebRTC carries it peer-to-peer over
  DTLS-SRTP, and the signaling payloads (SDP offers/answers, ICE candidates)
  are sealed browser-side with `nacl.box` between the participants' pinned
  identity keys — instances relay opaque ciphertext, so a compromised server
  cannot substitute DTLS fingerprints and man-in-the-middle a call.

  A ring is veejr's consent model applied to realtime: the callee's open
  tabs show an incoming-call banner and nothing connects until they accept.
  Only accepted friends can ring. For federated calls each instance holds a
  mirror `calls` row under the same public id and relays sealed signaling
  over the signed instance-to-instance channel — synchronously, not through
  the retry outbox, because a call is now or never.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Veejr.Accounts.User
  alias Veejr.Calls.{Call, CallParticipant, Notifier, ScheduledCall}
  alias Veejr.GuestConferences
  alias Veejr.GuestConferences.GuestCall
  alias Veejr.GuestConferences.GuestConference
  alias Veejr.Push
  alias Veejr.Repo
  alias Veejr.Social

  # A ring that nobody answered within this window counts as missed.
  @ring_timeout_seconds 60

  ## PubSub

  def subscribe(%Call{public_id: public_id}), do: subscribe(public_id)
  def subscribe(%GuestCall{public_id: public_id}), do: subscribe(public_id)
  def subscribe(public_id), do: Phoenix.PubSub.subscribe(Veejr.PubSub, topic(public_id))

  defp topic(public_id), do: "call:#{public_id}"

  defp broadcast(call, message) do
    Phoenix.PubSub.broadcast(Veejr.PubSub, topic(call.public_id), message)
  end

  ## Lifecycle

  @doc """
  Starts a call from `caller` to an accepted friend and rings them: local
  callees get a PubSub ring in every open tab; remote callees get a signed
  invite delivered to their instance, which rings them there. Returns
  `{:ok, call}` or an error (`:not_a_friend`, `:callee_unreachable`, …).
  """
  def start_call(%User{host: nil} = caller, callee_id) do
    callee = Repo.get(User, callee_id)

    cond do
      is_nil(callee) ->
        {:error, :not_found}

      callee.id == caller.id ->
        {:error, :self}

      not Social.friends?(caller.id, callee.id) ->
        {:error, :not_a_friend}

      true ->
        case active_call_between(caller.id, callee.id) do
          %Call{} = call ->
            {:ok, preload_call(call)}

          nil ->
            create_and_deliver_call(caller, callee)
        end
    end
  end

  defp create_and_deliver_call(caller, callee) do
    call =
      Repo.insert!(%Call{
        public_id: random_id(),
        caller_id: caller.id,
        callee_id: callee.id,
        state: "ringing"
      })

    # The caller is present from the moment they dial; the first invitee is
    # ringing. Everything after this reads membership from these rows.
    put_participant(call, caller.id, role: "caller", state: "joined", joined_at: now())
    put_participant(call, callee.id, role: "invitee", state: "ringing")

    call = %{call | caller: caller, callee: callee}

    if is_nil(callee.host) do
      ring_local(call, callee)
      {:ok, call}
    else
      case Veejr.Federation.deliver_call_invite(call, caller, callee) do
        :ok ->
          {:ok, call}

        {:error, reason} ->
          Logger.warning(
            "calls: invite to #{callee.username}@#{callee.host} failed: #{inspect(reason)}"
          )

          set_state(call, "failed")
          {:error, :callee_unreachable}
      end
    end
  end

  defp active_call_between(first_id, second_id) do
    from(call in Call,
      where:
        call.state in ["ringing", "accepted"] and
          ((call.caller_id == ^first_id and call.callee_id == ^second_id) or
             (call.caller_id == ^second_id and call.callee_id == ^first_id)),
      order_by: [desc: call.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Creates a ringing call after a host admits one waiting email guest."
  def start_guest_call(
        %User{id: host_id, host: nil} = host,
        %GuestConference{host_id: host_id, state: "waiting"} = conference
      ) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:call, %GuestCall{
      public_id: random_id(),
      host_id: host.id,
      guest_conference_id: conference.id,
      state: "ringing"
    })
    |> Ecto.Multi.update(
      :conference,
      Ecto.Changeset.change(conference,
        state: "admitted",
        admitted_at: DateTime.utc_now(:second)
      )
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{call: call, conference: admitted}} ->
        call = preload_guest_call(call)
        GuestConferences.broadcast_admitted(admitted, call)
        {:ok, call}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def start_guest_call(%User{}, %GuestConference{}), do: {:error, :unavailable}

  defp ring_local(call, %User{} = callee) do
    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      "user:#{callee.id}",
      {:veejr_call_ring, call}
    )
  end

  @doc "Fetches a call by public id, only for its participants."
  def get_call(%User{id: user_id}, public_id) when is_binary(public_id) do
    case Repo.get_by(Call, public_id: public_id) do
      nil ->
        {:error, :not_found}

      %Call{} = call ->
        # Membership, not the legacy caller/callee pair: a third participant
        # is authorised by their participant row alone.
        if participant(call, user_id) do
          {:ok, preload_call(call)}
        else
          {:error, :not_found}
        end
    end
  end

  @doc "Fetches the active call associated with an authorized guest capability."
  def get_guest_call(%GuestConference{id: conference_id}) do
    case Repo.get_by(GuestCall, guest_conference_id: conference_id) do
      nil -> {:error, :not_found}
      call -> {:ok, preload_guest_call(call)}
    end
  end

  def get_guest_call_for_host(%User{id: host_id}, public_id) when is_binary(public_id) do
    case Repo.get_by(GuestCall, public_id: public_id, host_id: host_id) do
      nil -> {:error, :not_found}
      call -> {:ok, preload_guest_call(call)}
    end
  end

  @doc """
  Returns the newest call ringing this user, if one exists.

  Keyed on the participant row rather than `callee_id` so someone added to an
  already-accepted call is rung the same way the first invitee was.
  """
  def pending_ring(%User{id: user_id}) do
    from(c in Call,
      join: p in CallParticipant,
      on: p.call_id == c.id,
      where:
        p.user_id == ^user_id and p.state == "ringing" and c.state in ["ringing", "accepted"],
      order_by: [desc: c.inserted_at],
      limit: 1,
      preload: [:caller, :callee]
    )
    |> Repo.one()
  end

  ## Participants

  @doc "Lists a call's participants, newest membership last, with users preloaded."
  def participants(%Call{id: call_id}) do
    from(p in CallParticipant,
      where: p.call_id == ^call_id,
      order_by: [asc: p.inserted_at, asc: p.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc "The participants a given user should hold a peer connection to."
  def peer_participants(%Call{} = call, user_id) do
    call
    |> participants()
    |> Enum.filter(&(&1.user_id != user_id and &1.state in CallParticipant.active_states()))
  end

  @doc "One participant row, or nil."
  def participant(%Call{id: call_id}, user_id) do
    Repo.get_by(CallParticipant, call_id: call_id, user_id: user_id)
  end

  @doc """
  Adds another local friend to an accepted call and rings them.

  Only the caller may add: with three people the question "who let them in?"
  needs one answer, and the host is the least surprising one. Remote users are
  refused because federated call invites are strictly 1:1.
  """
  def add_participant(%User{id: user_id} = caller, public_id, invitee_id) do
    with {:ok, %Call{caller_id: ^user_id} = call} <- get_call(caller, public_id),
         {:ok, invitee_id} <- parse_id(invitee_id),
         %User{} = invitee <- Repo.get(User, invitee_id) || {:error, :not_found} do
      cond do
        call.state not in ["ringing", "accepted"] ->
          {:error, {:bad_state, call.state}}

        not is_nil(invitee.host) ->
          {:error, :remote_participant}

        invitee.id == caller.id ->
          {:error, :self}

        not Social.friends?(caller.id, invitee.id) ->
          {:error, :not_a_friend}

        match?(
          %CallParticipant{state: state} when state in ["ringing", "joined"],
          participant(call, invitee.id)
        ) ->
          {:error, :already_participating}

        length(active_participants(call)) >= max_participants() ->
          {:error, :call_full}

        true ->
          put_participant(call, invitee.id, role: "invitee", state: "ringing")
          call = preload_call(call)
          ring_local(call, invitee)
          broadcast(call, {:call_participants_changed, call.public_id})
          {:ok, call}
      end
    else
      {:ok, %Call{}} -> {:error, :not_caller}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The number of people a single call may hold, mesh upload being quadratic."
  def max_participants, do: Application.get_env(:veejr, :max_call_participants, 3)

  defp active_participants(%Call{} = call) do
    call
    |> participants()
    |> Enum.filter(&(&1.state in CallParticipant.active_states()))
  end

  defp put_participant(%Call{id: call_id}, user_id, attrs) do
    attrs = Map.new(attrs)

    case Repo.get_by(CallParticipant, call_id: call_id, user_id: user_id) do
      nil ->
        %CallParticipant{call_id: call_id, user_id: user_id}
        |> Ecto.Changeset.change(attrs)
        |> Repo.insert!()

      %CallParticipant{} = existing ->
        existing
        |> Ecto.Changeset.change(attrs)
        |> Repo.update!()
    end
  end

  defp now, do: DateTime.utc_now(:second)

  ## Scheduled calls

  @doc "Lists a participant's recent and upcoming scheduled calls."
  def list_scheduled_calls(%User{id: user_id}) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -24, :hour)

    from(schedule in ScheduledCall,
      where:
        (schedule.organizer_id == ^user_id or schedule.invitee_id == ^user_id) and
          schedule.scheduled_for >= ^cutoff,
      order_by: [asc: schedule.scheduled_for],
      preload: [:organizer, :invitee]
    )
    |> Repo.all()
  end

  @doc "Fetches one scheduled call, scoped to either participant."
  def get_scheduled_call(%User{id: user_id}, id) do
    from(schedule in ScheduledCall,
      where:
        schedule.id == ^id and
          (schedule.organizer_id == ^user_id or schedule.invitee_id == ^user_id),
      preload: [:organizer, :invitee]
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      schedule -> {:ok, schedule}
    end
  end

  @doc "Schedules a future call with an accepted friend."
  def schedule_call(%User{host: nil} = organizer, invitee_id, attrs) do
    with {:ok, invitee_id} <- parse_id(invitee_id),
         %User{} = invitee <- Repo.get(User, invitee_id) || {:error, :not_found},
         true <- invitee.id != organizer.id || {:error, :self},
         true <- Social.friends?(organizer.id, invitee.id) || {:error, :not_a_friend} do
      %ScheduledCall{
        public_id: random_id(),
        organizer_id: organizer.id,
        invitee_id: invitee.id
      }
      |> ScheduledCall.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, schedule} ->
          schedule = preload_schedule(schedule)

          case Veejr.Federation.deliver_call_schedule(
                 schedule,
                 organizer,
                 invitee,
                 "scheduled"
               ) do
            :ok ->
              notify_schedule_created(schedule)
              {:ok, schedule}

            {:error, reason} ->
              Repo.delete!(schedule)
              {:error, reason}
          end

        error ->
          error
      end
    else
      error -> error
    end
  end

  @doc "Updates the shared call notes. The organizer remains authoritative."
  def update_scheduled_call_note(%User{id: user_id} = user, id, attrs) do
    with {:ok, %ScheduledCall{organizer_id: ^user_id} = schedule} <-
           get_scheduled_call(user, id),
         {:ok, schedule} <-
           schedule
           |> ScheduledCall.note_changeset(attrs)
           |> Repo.update() do
      schedule = preload_schedule(schedule)
      notify_schedule(schedule, :updated)

      _delivery =
        Veejr.Federation.deliver_call_schedule(
          schedule,
          schedule.organizer,
          schedule.invitee,
          "updated"
        )

      {:ok, schedule}
    else
      {:ok, %ScheduledCall{}} -> {:error, :not_organizer}
      error -> error
    end
  end

  @doc "Cancels a scheduled call as either participant, with an optional reason."
  def cancel_scheduled_call(%User{id: user_id} = user, id, attrs \\ %{}) do
    with {:ok, %ScheduledCall{status: "scheduled"} = schedule} <-
           get_scheduled_call(user, id),
         {:ok, schedule} <-
           schedule
           |> ScheduledCall.cancellation_changeset(attrs, user_id)
           |> Repo.update() do
      schedule =
        schedule
        |> preload_schedule()

      notify_schedule(schedule, :cancelled)

      peer =
        if schedule.organizer_id == user_id,
          do: schedule.invitee,
          else: schedule.organizer

      _delivery =
        Veejr.Federation.deliver_call_schedule_cancellation(
          schedule,
          user,
          peer
        )

      _email = Notifier.deliver_cancellation(schedule, user, peer)

      {:ok, schedule}
    else
      {:ok, %ScheduledCall{}} -> {:error, :not_scheduled}
      error -> error
    end
  end

  @doc "Starts a scheduled call. The organizer sends the realtime invitation."
  def start_scheduled_call(%User{id: user_id} = user, id) do
    with {:ok, %ScheduledCall{organizer_id: ^user_id, status: "scheduled"} = schedule} <-
           get_scheduled_call(user, id),
         {:ok, call} <- start_call(user, schedule.invitee_id) do
      schedule =
        schedule
        |> Ecto.Changeset.change(status: "started")
        |> Repo.update!()
        |> preload_schedule()

      notify_schedule(schedule, :started)

      _delivery =
        Veejr.Federation.deliver_call_schedule(
          schedule,
          schedule.organizer,
          schedule.invitee,
          "started"
        )

      {:ok, call}
    else
      {:ok, %ScheduledCall{}} -> {:error, :not_scheduled}
      error -> error
    end
  end

  @doc "Creates the local mirror of a schedule from a verified peer."
  def receive_remote_schedule(
        %User{} = remote_organizer,
        %User{host: nil} = local_invitee,
        public_id,
        attrs
      )
      when is_binary(public_id) do
    cond do
      not Social.friends?(remote_organizer.id, local_invitee.id) ->
        {:error, :not_friends}

      byte_size(public_id) > 100 ->
        {:error, :bad_request}

      schedule = Repo.get_by(ScheduledCall, public_id: public_id) ->
        schedule = preload_schedule(schedule)

        if schedule.organizer_id == remote_organizer.id and
             schedule.invitee_id == local_invitee.id do
          {:ok, schedule}
        else
          {:error, :origin_mismatch}
        end

      true ->
        %ScheduledCall{
          public_id: public_id,
          organizer_id: remote_organizer.id,
          invitee_id: local_invitee.id
        }
        |> ScheduledCall.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, schedule} ->
            schedule = preload_schedule(schedule)
            notify_schedule_created(schedule)
            {:ok, schedule}

          {:error, _changeset} ->
            {:error, :bad_request}
        end
    end
  end

  @doc "Applies a participant-authored cancellation from a verified peer."
  def receive_remote_schedule_cancellation(
        public_id,
        verified_authority,
        %User{} = remote_canceller,
        %User{host: nil} = local_recipient,
        attrs
      ) do
    with %ScheduledCall{} = schedule <-
           Repo.get_by(ScheduledCall, public_id: public_id) || {:error, :not_found},
         schedule <- preload_schedule(schedule),
         true <- remote_canceller.host == verified_authority || {:error, :origin_mismatch},
         true <-
           scheduled_call_participants?(schedule, remote_canceller, local_recipient) ||
             {:error, :origin_mismatch} do
      if schedule.status == "scheduled" do
        case schedule
             |> ScheduledCall.cancellation_changeset(attrs, remote_canceller.id)
             |> Repo.update() do
          {:ok, schedule} ->
            schedule = preload_schedule(schedule)
            notify_schedule(schedule, :cancelled)
            _email = Notifier.deliver_cancellation(schedule, remote_canceller, local_recipient)
            {:ok, :applied}

          {:error, _changeset} ->
            {:error, :bad_request}
        end
      else
        {:ok, :applied}
      end
    end
  end

  @doc "Applies a cancelled or started schedule update from its verified home peer."
  def receive_remote_schedule_update(public_id, verified_authority, event)
      when event in ["cancelled", "started"] do
    with %ScheduledCall{} = schedule <-
           Repo.get_by(ScheduledCall, public_id: public_id) || {:error, :not_found},
         schedule <- preload_schedule(schedule),
         true <- schedule.organizer.host == verified_authority || {:error, :origin_mismatch} do
      if schedule.status == "scheduled" do
        schedule =
          schedule
          |> Ecto.Changeset.change(status: event)
          |> Repo.update!()
          |> preload_schedule()

        notify_schedule(schedule, String.to_existing_atom(event))

        if event == "cancelled" do
          _email = Notifier.deliver_cancellation(schedule, schedule.organizer, schedule.invitee)
        end
      end

      {:ok, :applied}
    end
  end

  def receive_remote_schedule_update(_public_id, _verified_authority, _event),
    do: {:error, :bad_request}

  @doc "Applies organizer-owned shared notes from a verified federated peer."
  def receive_remote_schedule_note_update(public_id, verified_authority, attrs) do
    with %ScheduledCall{} = schedule <-
           Repo.get_by(ScheduledCall, public_id: public_id) || {:error, :not_found},
         schedule <- preload_schedule(schedule),
         true <- schedule.organizer.host == verified_authority || {:error, :origin_mismatch},
         {:ok, schedule} <-
           schedule
           |> ScheduledCall.note_changeset(attrs)
           |> Repo.update() do
      schedule = preload_schedule(schedule)
      notify_schedule(schedule, :updated)
      {:ok, :applied}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :bad_request}
      error -> error
    end
  end

  @doc "Dispatches configured notifications and fixed two-minute email reminders."
  def dispatch_due_reminders(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -1, :hour)
    horizon = DateTime.add(now, 1, :day)
    email_horizon = DateTime.add(now, 2, :minute)

    schedules =
      from(schedule in ScheduledCall,
        where:
          schedule.status == "scheduled" and is_nil(schedule.reminded_at) and
            schedule.scheduled_for >= ^cutoff and schedule.scheduled_for <= ^horizon,
        preload: [:organizer, :invitee]
      )
      |> Repo.all()
      |> Enum.filter(fn schedule ->
        reminder_at = DateTime.add(schedule.scheduled_for, -schedule.reminder_minutes, :minute)
        DateTime.compare(reminder_at, now) != :gt
      end)

    Enum.each(schedules, fn schedule ->
      schedule
      |> Ecto.Changeset.change(reminded_at: now)
      |> Repo.update!()
      |> preload_schedule()
      |> notify_schedule(:reminder)
    end)

    email_schedules =
      from(schedule in ScheduledCall,
        join: organizer in assoc(schedule, :organizer),
        join: invitee in assoc(schedule, :invitee),
        where:
          schedule.status == "scheduled" and
            schedule.scheduled_for >= ^cutoff and
            schedule.scheduled_for <= ^email_horizon and
            ((is_nil(organizer.host) and is_nil(schedule.organizer_email_reminded_at)) or
               (is_nil(invitee.host) and is_nil(schedule.invitee_email_reminded_at))),
        preload: [:organizer, :invitee]
      )
      |> Repo.all()

    emailed =
      Enum.reduce(email_schedules, 0, fn schedule, delivered ->
        Enum.reduce(due_email_recipients(schedule), delivered, fn {recipient, field}, count ->
          case Notifier.deliver_two_minute_reminder(schedule, recipient) do
            {:ok, _email} ->
              schedule
              |> Ecto.Changeset.change([{field, now}])
              |> Repo.update!()

              count + 1

            {:error, _reason} ->
              count
          end
        end)
      end)

    %{reminded: length(schedules), emailed: emailed}
  end

  @doc """
  The callee has opened the call page: the ring is answered. Tells the
  caller's side (locally or over federation) so it starts WebRTC
  negotiation — the caller never sends an offer into the void.
  """
  def join_call(%User{id: user_id} = user, public_id) do
    with {:ok, %Call{} = call} <- get_call(user, public_id),
         %CallParticipant{state: "ringing"} <- participant(call, user_id) do
      put_participant(call, user_id, state: "joined", joined_at: now())

      # The call itself flips to accepted on the first join and stays there
      # while later participants come and go.
      call = if call.state == "ringing", do: set_state(call, "accepted"), else: call

      broadcast(call, {:call_peer_joined, call.public_id, user_id})
      broadcast(call, {:call_participants_changed, call.public_id})

      relay_to_remote_peer(call, user, fn authority ->
        Veejr.Federation.deliver_call_update(authority, call, "joined")
      end)

      {:ok, call}
    else
      {:ok, %Call{} = call} -> {:error, {:bad_state, call.state}}
      %CallParticipant{state: state} -> {:error, {:bad_state, state}}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Re-announces an accepted callee after their call page reconnects.

  This lets the caller restart negotiation when an offer was lost during a
  mobile reconnect or full-page reload.
  """
  def rejoin_call(%User{id: user_id} = user, public_id) do
    with {:ok, %Call{state: "accepted"} = call} <- get_call(user, public_id),
         %CallParticipant{state: "joined"} <- participant(call, user_id) do
      broadcast(call, {:call_peer_joined, call.public_id, user_id})

      relay_to_remote_peer(call, user, fn authority ->
        Veejr.Federation.deliver_call_update(authority, call, "joined")
      end)

      {:ok, call}
    else
      {:ok, %Call{} = call} -> {:error, {:bad_state, call.state}}
      %CallParticipant{state: state} -> {:error, {:bad_state, state}}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Joins a ringing call from its admitted temporary guest side."
  def join_guest_call(%GuestConference{} = conference) do
    with {:ok, %GuestCall{state: "ringing"} = call} <- get_guest_call(conference) do
      call = set_guest_state(call, "accepted")
      # Guest calls are always exactly two people, so the guest's arrival is
      # announced without a participant id; the host holds one peer.
      broadcast(call, {:call_peer_joined, call.public_id, :guest})
      {:ok, call}
    else
      {:ok, %GuestCall{} = call} -> {:error, {:bad_state, call.state}}
      error -> error
    end
  end

  @doc "Declines a ringing call (callee side)."
  def decline_call(%User{} = user, public_id), do: decline_call(user, public_id, "declined")

  @doc "Declines a ringing call and optionally sends the caller the non-content busy outcome."
  def decline_call(%User{id: user_id} = user, public_id, reason)
      when reason in ["declined", "busy"] do
    with {:ok, %Call{} = call} <- get_call(user, public_id),
         %CallParticipant{state: "ringing"} <- participant(call, user_id) do
      put_participant(call, user_id, state: reason_state(reason), left_at: now())
      notify_ring_cancelled(call, user_id)

      relay_to_remote_peer(call, user, fn authority ->
        Veejr.Federation.deliver_call_update(authority, call, reason)
      end)

      # One invitee declining only ends the call when it leaves too few people
      # to talk to. In a 1:1 that is always; in a 3-way the other two continue.
      {:ok, settle(call, reason)}
    else
      {:ok, %Call{}} -> {:error, :not_ringing}
      %CallParticipant{} -> {:error, :not_ringing}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp reason_state("busy"), do: "busy"
  defp reason_state(_), do: "declined"

  # Ends the call when fewer than two participants can still be in it,
  # otherwise leaves it running and tells the remaining pages who changed.
  defp settle(%Call{} = call, reason) do
    call = preload_call(call)
    remaining = active_participants(call)

    if length(remaining) < 2 do
      final =
        cond do
          reason in ["declined", "busy"] and call.state == "ringing" -> "declined"
          call.state == "ringing" -> "missed"
          true -> "ended"
        end

      ended = set_state(call, final)
      Enum.each(remaining, &put_participant(call, &1.user_id, state: "left", left_at: now()))

      broadcast(
        ended,
        {:call_ended, ended.public_id, if(final == "declined", do: reason, else: final)}
      )

      ended
    else
      broadcast(call, {:call_participants_changed, call.public_id})
      call
    end
  end

  @doc "Cancels an unanswered invitation from its caller side."
  def cancel_call(%User{id: user_id} = user, public_id) do
    with {:ok, %Call{caller_id: ^user_id, state: "ringing"} = call} <-
           get_call(user, public_id) do
      call = set_state(call, "cancelled")

      # Clear the ring banners *before* marking anyone left: the notify step
      # looks for participants still in "ringing", so reordering these two
      # silently stops stale banners from being dismissed.
      notify_ring_cancelled(call)

      Enum.each(active_participants(call), fn participant ->
        put_participant(call, participant.user_id, state: "left", left_at: now())
      end)

      broadcast(call, {:call_ended, call.public_id, "cancelled"})

      relay_to_remote_peer(call, user, fn authority ->
        Veejr.Federation.deliver_call_update(authority, call, "cancelled")
      end)

      {:ok, call}
    else
      {:ok, %Call{}} -> {:error, :not_ringing}
      error -> error
    end
  end

  @doc """
  Leaves a call: hang-up, or cancel while still ringing.

  With more than two people this is a departure rather than an ending — the
  call only ends once fewer than two participants remain.
  """
  def end_call(%User{id: user_id} = user, public_id) do
    with {:ok, %Call{} = call} <- get_call(user, public_id) do
      if call.state in ["ringing", "accepted"] do
        put_participant(call, user_id, state: "left", left_at: now())

        relay_to_remote_peer(call, user, fn authority ->
          Veejr.Federation.deliver_call_update(authority, call, "ended")
        end)

        case settle(call, "left") do
          %Call{state: state} when state in ["ringing", "accepted"] ->
            # Others are still talking; tell them who left so their meshes
            # can drop that peer connection.
            broadcast(call, {:call_participant_left, call.public_id, user_id})

          _ended ->
            :ok
        end
      end

      :ok
    end
  end

  @doc "Ends a guest call using its emailed capability."
  def end_guest_call(%GuestConference{} = conference) do
    with {:ok, %GuestCall{} = call} <- get_guest_call(conference) do
      if call.state in ["ringing", "accepted"] do
        final = if call.state == "ringing", do: "missed", else: "ended"
        call = set_guest_state(call, final)
        broadcast(call, {:call_ended, call.public_id, final})
        finish_guest_conference(call)
      end

      :ok
    end
  end

  def end_guest_host_call(
        %User{id: host_id},
        %GuestCall{host_id: host_id, guest_conference: %GuestConference{} = conference}
      ) do
    end_guest_call(conference)
  end

  def end_guest_host_call(%User{}, %GuestCall{}), do: {:error, :not_found}

  @doc "Ends an accepted call because one participant remained offline beyond the grace period."
  def disconnect_call(%User{id: user_id} = user, public_id) do
    with {:ok, %Call{state: "accepted"} = call} <- get_call(user, public_id) do
      call = set_state(call, "ended")
      broadcast(call, {:call_disconnected, call.public_id, user_id})

      relay_to_remote_peer(call, user, fn authority ->
        Veejr.Federation.deliver_call_update(authority, call, "disconnected")
      end)

      :ok
    else
      {:ok, %Call{state: "ringing"}} -> end_call(user, public_id)
      {:ok, %Call{}} -> :ok
      error -> error
    end
  end

  @doc """
  Relays one sealed signaling payload (offer/answer/ICE) to one peer. The
  payload is `nacl.box` ciphertext produced in the sender's browser — the
  server cannot read or alter it. Remote peers get it over the signed
  federation channel, in the background so a slow peer instance never
  blocks the sender's socket.

  `target_user_id` addresses the payload. It matters beyond tidiness: with
  three people on a call, an unaddressed broadcast means everyone receives
  everyone else's offers with no way to tell which pairing a given SDP
  belongs to. `nil` means "the other side", which is what a 1:1 or a
  federated call always means.
  """
  def signal(%User{id: user_id} = user, public_id, ciphertext, nonce, target_user_id \\ nil)
      when is_binary(ciphertext) and is_binary(nonce) do
    with {:ok, %Call{state: "accepted"} = call} <- get_call(user, public_id) do
      target = target_user_id || implicit_target(call, user_id)
      broadcast(call, {:call_signal, call.public_id, user_id, target, ciphertext, nonce})

      relay_to_remote_peer(call, user, fn authority ->
        Task.Supervisor.start_child(Veejr.TaskSupervisor, fn ->
          Veejr.Federation.deliver_call_signal(authority, call, ciphertext, nonce)
        end)

        :ok
      end)

      :ok
    else
      {:ok, %Call{} = call} -> {:error, {:bad_state, call.state}}
      error -> error
    end
  end

  # A 1:1 call has exactly one possible recipient, so older clients that send
  # no target still route correctly.
  defp implicit_target(%Call{} = call, sender_id) do
    case peer_participants(call, sender_id) do
      [%CallParticipant{user_id: target}] -> target
      _ -> nil
    end
  end

  @doc "Relays one sealed signaling payload from an authorized temporary guest."
  def signal_guest(%GuestConference{id: conference_id} = conference, ciphertext, nonce)
      when is_binary(ciphertext) and is_binary(nonce) do
    with {:ok, %GuestCall{state: "accepted"} = call} <- get_guest_call(conference) do
      # Guest calls are always exactly two people, so :any addresses "the
      # other side" without needing a participant id.
      broadcast(
        call,
        {:call_signal, call.public_id, {:guest, conference_id}, :any, ciphertext, nonce}
      )

      :ok
    else
      {:ok, %GuestCall{} = call} -> {:error, {:bad_state, call.state}}
      error -> error
    end
  end

  def signal_guest_host(
        %User{} = host,
        %GuestCall{public_id: public_id},
        ciphertext,
        nonce
      )
      when is_binary(ciphertext) and is_binary(nonce) do
    with {:ok, %GuestCall{state: "accepted"} = call} <-
           get_guest_call_for_host(host, public_id) do
      broadcast(call, {:call_signal, call.public_id, host.id, :any, ciphertext, nonce})
      :ok
    else
      {:ok, %GuestCall{} = call} -> {:error, {:bad_state, call.state}}
      error -> error
    end
  end

  ## Federation (inbound, authorities already verified by FederationAuth)

  @doc "Creates the mirror row for an invite from a verified peer and rings the callee."
  def receive_remote_invite(%User{} = remote_caller, %User{host: nil} = local_callee, public_id)
      when is_binary(public_id) do
    cond do
      not Social.friends?(remote_caller.id, local_callee.id) ->
        {:error, :not_friends}

      Repo.get_by(Call, public_id: public_id) ->
        {:ok, :duplicate}

      byte_size(public_id) > 100 ->
        {:error, :bad_request}

      true ->
        call =
          Repo.insert!(%Call{
            public_id: public_id,
            caller_id: remote_caller.id,
            callee_id: local_callee.id,
            state: "ringing"
          })

        # The mirror row gets participants too, so authorisation and peer
        # lookup work the same way on both sides. Federated calls stay 1:1 —
        # add_participant/3 refuses remote users.
        put_participant(call, remote_caller.id, role: "caller", state: "joined", joined_at: now())
        put_participant(call, local_callee.id, role: "invitee", state: "ringing")

        ring_local(%{call | caller: remote_caller, callee: local_callee}, local_callee)
        {:ok, :created}
    end
  end

  @doc "Applies a joined/declined/busy/ended/disconnected update relayed by the remote instance."
  def receive_remote_update(public_id, verified_authority, event)
      when event in ["joined", "declined", "busy", "cancelled", "ended", "disconnected"] do
    with {:ok, call} <- remote_party_call(public_id, verified_authority) do
      case event do
        "joined" when call.state == "ringing" ->
          call = set_state(call, "accepted")
          broadcast(call, {:call_peer_joined, call.public_id})

        "joined" when call.state == "accepted" ->
          broadcast(call, {:call_peer_joined, call.public_id})

        "declined" when call.state == "ringing" ->
          call = set_state(call, "declined")
          broadcast(call, {:call_ended, call.public_id, "declined"})

        "busy" when call.state == "ringing" ->
          call = set_state(call, "declined")
          broadcast(call, {:call_ended, call.public_id, "busy"})

        "cancelled" when call.state == "ringing" ->
          call = set_state(call, "cancelled")
          broadcast(call, {:call_ended, call.public_id, "cancelled"})
          notify_ring_cancelled(call)

        "ended" when call.state in ["ringing", "accepted"] ->
          final = if call.state == "ringing", do: "missed", else: "ended"
          call = set_state(call, final)
          broadcast(call, {:call_ended, call.public_id, final})

        "disconnected" when call.state == "accepted" ->
          remote = if call.caller.host, do: call.caller, else: call.callee
          call = set_state(call, "ended")
          broadcast(call, {:call_disconnected, call.public_id, remote.id})

        _ ->
          :ok
      end

      {:ok, :applied}
    end
  end

  def receive_remote_update(_public_id, _authority, _event), do: {:error, :bad_request}

  @doc "Delivers a sealed signaling payload relayed by the remote participant's instance."
  def receive_remote_signal(public_id, verified_authority, ciphertext, nonce)
      when is_binary(ciphertext) and is_binary(nonce) do
    with {:ok, %Call{state: "accepted"} = call} <-
           remote_party_call(public_id, verified_authority) do
      remote = if call.caller.host, do: call.caller, else: call.callee
      # Federated calls are strictly 1:1, so the local side is the only target.
      broadcast(call, {:call_signal, call.public_id, remote.id, :any, ciphertext, nonce})
      {:ok, :relayed}
    else
      {:ok, %Call{}} -> {:error, :bad_request}
      error -> error
    end
  end

  def receive_remote_signal(_public_id, _authority, _ciphertext, _nonce),
    do: {:error, :bad_request}

  # The call must exist and its remote participant must live on exactly the
  # authority whose signature was verified — instance B cannot speak about
  # calls it is not a party to.
  defp remote_party_call(public_id, verified_authority) do
    with %Call{} = call <-
           Repo.get_by(Call, public_id: public_id) || {:error, :not_found},
         call = Repo.preload(call, [:caller, :callee]),
         true <-
           (call.caller.host == verified_authority or call.callee.host == verified_authority) ||
             {:error, :origin_mismatch} do
      {:ok, call}
    end
  end

  ## Participant presence

  # Mobile browsers drop and reconnect the LiveView socket constantly, and a
  # reconnect must not read as "hung up". Each mounted call page registers
  # here; leaving only ends the call if the participant stays absent through
  # a short grace period.

  @grace_ms 25_000

  @doc "Registers the calling process as a participant's live call page."
  def register_presence(public_id, user_id) do
    Registry.register(Veejr.CallRegistry, {public_id, user_id}, :present)
    :ok
  end

  @doc "Whether any live call page is currently open for this participant."
  def present?(public_id, user_id) do
    Registry.lookup(Veejr.CallRegistry, {public_id, user_id}) != []
  end

  @doc """
  Ends the call only if the participant has not re-registered (reconnected
  or reopened the page) within the grace period. A genuine navigation away
  or closed tab still hangs up — just not a network blip.
  """
  def end_call_after_grace(%User{} = user, public_id) do
    case Application.get_env(:veejr, :call_grace_ms, @grace_ms) do
      :never ->
        :ok

      grace_ms ->
        Task.Supervisor.start_child(Veejr.TaskSupervisor, fn ->
          Process.sleep(grace_ms)

          unless present?(public_id, user.id) do
            disconnect_call(user, public_id)
          end
        end)

        :ok
    end
  end

  @doc "Applies the same reconnect grace period to a temporary guest tab."
  def end_guest_call_after_grace(%GuestConference{} = conference) do
    case Application.get_env(:veejr, :call_grace_ms, @grace_ms) do
      :never ->
        :ok

      grace_ms ->
        Task.Supervisor.start_child(Veejr.TaskSupervisor, fn ->
          Process.sleep(grace_ms)

          case get_guest_call(conference) do
            {:ok, call} ->
              unless present?(call.public_id, guest_presence_id(conference)) do
                end_guest_call(conference)
              end

            _ ->
              :ok
          end
        end)

        :ok
    end
  end

  def end_guest_host_call_after_grace(%User{} = host, %GuestCall{} = call) do
    case Application.get_env(:veejr, :call_grace_ms, @grace_ms) do
      :never ->
        :ok

      grace_ms ->
        Task.Supervisor.start_child(Veejr.TaskSupervisor, fn ->
          Process.sleep(grace_ms)

          unless present?(call.public_id, host.id) do
            end_guest_host_call(host, call)
          end
        end)

        :ok
    end
  end

  def guest_presence_id(%GuestConference{id: id}), do: {:guest, id}

  ## Maintenance

  @doc "Marks stale ringing calls missed and abandons ancient accepted calls."
  def sweep_stale_calls do
    ring_cutoff = DateTime.add(DateTime.utc_now(:second), -@ring_timeout_seconds, :second)
    active_cutoff = DateTime.add(DateTime.utc_now(:second), -24, :hour)

    {missed, _} =
      from(c in Call, where: c.state == "ringing" and c.inserted_at < ^ring_cutoff)
      |> Repo.update_all(set: [state: "missed"])

    {ended, _} =
      from(c in Call, where: c.state == "accepted" and c.updated_at < ^active_cutoff)
      |> Repo.update_all(set: [state: "ended"])

    %{missed: missed, ended: ended}
  end

  ## Helpers

  defp relay_to_remote_peer(%Call{} = call, %User{id: user_id}, fun) do
    peer = if call.caller_id == user_id, do: call.callee, else: call.caller

    case peer do
      %User{host: authority} when is_binary(authority) -> fun.(authority)
      _ -> :ok
    end
  end

  # Clears stale ring banners. Without a user id every still-ringing local
  # participant is cleared (the whole call went away); with one, just that
  # person's own banner.
  defp notify_ring_cancelled(%Call{} = call), do: notify_ring_cancelled(call, :all)

  defp notify_ring_cancelled(%Call{} = call, :all) do
    call
    |> participants()
    |> Enum.filter(&(&1.state == "ringing" and is_nil(&1.user.host)))
    |> Enum.each(&clear_ring(call, &1.user_id))
  end

  defp notify_ring_cancelled(%Call{} = call, user_id) when is_integer(user_id) do
    clear_ring(call, user_id)
  end

  defp clear_ring(%Call{} = call, user_id) do
    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      "user:#{user_id}",
      {:veejr_call_cancelled, call.public_id}
    )
  end

  defp notify_schedule_created(%ScheduledCall{invitee: %User{host: nil}} = schedule) do
    notify_schedule_user(schedule, schedule.invitee, :scheduled)
    _delivery = Notifier.deliver_invitation(schedule)
    schedule
  end

  defp notify_schedule_created(%ScheduledCall{}), do: :ok

  defp notify_schedule(%ScheduledCall{} = schedule, event) do
    schedule
    |> local_schedule_users()
    |> Enum.each(&notify_schedule_user(schedule, &1, event))

    schedule
  end

  defp notify_schedule_user(schedule, user, event) do
    peer = if user.id == schedule.organizer_id, do: schedule.invitee, else: schedule.organizer

    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      "user:#{user.id}",
      {:veejr_call_schedule, event, schedule, peer}
    )

    if event in [:scheduled, :reminder] do
      Push.notify_user_async(user, schedule_push_payload(schedule, peer, event))
    end
  end

  defp scheduled_call_participants?(schedule, first, second) do
    (schedule.organizer_id == first.id and schedule.invitee_id == second.id) or
      (schedule.organizer_id == second.id and schedule.invitee_id == first.id)
  end

  defp schedule_push_payload(schedule, peer, :scheduled) do
    %{
      title: "Call scheduled",
      body: "#{Social.Address.handle(peer)} scheduled a call with you.",
      url: "/calls",
      type: "call_scheduled",
      scheduled_call_id: schedule.public_id
    }
  end

  defp schedule_push_payload(schedule, peer, :reminder) do
    %{
      title: "Scheduled call reminder",
      body: "Your call with #{Social.Address.handle(peer)} is coming up.",
      url: "/calls",
      type: "call_reminder",
      scheduled_call_id: schedule.public_id
    }
  end

  defp local_schedule_users(schedule) do
    [schedule.organizer, schedule.invitee]
    |> Enum.filter(&is_nil(&1.host))
  end

  defp due_email_recipients(schedule) do
    [
      {schedule.organizer, :organizer_email_reminded_at, schedule.organizer_email_reminded_at},
      {schedule.invitee, :invitee_email_reminded_at, schedule.invitee_email_reminded_at}
    ]
    |> Enum.filter(fn {user, _field, reminded_at} ->
      is_nil(user.host) and is_nil(reminded_at)
    end)
    |> Enum.map(fn {user, field, _reminded_at} -> {user, field} end)
  end

  defp preload_schedule(schedule), do: Repo.preload(schedule, [:organizer, :invitee], force: true)

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :not_found}
    end
  end

  defp parse_id(_id), do: {:error, :not_found}

  defp finish_guest_conference(%GuestCall{guest_conference: %GuestConference{} = conference}) do
    GuestConferences.mark_ended(conference)
    :ok
  end

  defp preload_call(call) do
    Repo.preload(call, [:caller, :callee])
  end

  defp preload_guest_call(call) do
    Repo.preload(call, [:host, :guest_conference])
  end

  defp set_state(%Call{} = call, state)
       when state in ~w(ringing accepted declined cancelled missed ended failed) do
    call
    |> Ecto.Changeset.change(state: state)
    |> Repo.update!()
    |> Map.merge(%{caller: call.caller, callee: call.callee})
  end

  defp set_guest_state(%GuestCall{} = call, state)
       when state in ~w(ringing accepted declined missed ended failed) do
    call
    |> Ecto.Changeset.change(state: state)
    |> Repo.update!()
    |> Map.merge(%{host: call.host, guest_conference: call.guest_conference})
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
