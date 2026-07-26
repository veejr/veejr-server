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
  alias Veejr.Calls.{Call, ScheduledCall}
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
        call =
          Repo.insert!(%Call{
            public_id: random_id(),
            caller_id: caller.id,
            callee_id: callee.id,
            state: "ringing"
          })

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
      %Call{caller_id: ^user_id} = call -> {:ok, preload_call(call)}
      %Call{callee_id: ^user_id} = call -> {:ok, preload_call(call)}
      _ -> {:error, :not_found}
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

  @doc "Returns the newest unanswered call for a local callee, if one exists."
  def pending_ring(%User{id: user_id}) do
    from(c in Call,
      where: c.callee_id == ^user_id and c.state == "ringing",
      order_by: [desc: c.inserted_at],
      limit: 1,
      preload: [:caller, :callee]
    )
    |> Repo.one()
  end

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

  @doc "Cancels a scheduled call. Only its organizer may cancel it."
  def cancel_scheduled_call(%User{id: user_id} = user, id) do
    with {:ok, %ScheduledCall{organizer_id: ^user_id, status: "scheduled"} = schedule} <-
           get_scheduled_call(user, id) do
      schedule =
        schedule
        |> Ecto.Changeset.change(status: "cancelled")
        |> Repo.update!()
        |> preload_schedule()

      notify_schedule(schedule, :cancelled)

      _delivery =
        Veejr.Federation.deliver_call_schedule(
          schedule,
          schedule.organizer,
          schedule.invitee,
          "cancelled"
        )

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
      end

      {:ok, :applied}
    end
  end

  def receive_remote_schedule_update(_public_id, _verified_authority, _event),
    do: {:error, :bad_request}

  @doc "Dispatches persisted reminders whose configured lead time has elapsed."
  def dispatch_due_reminders(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -1, :hour)
    horizon = DateTime.add(now, 1, :day)

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

    %{reminded: length(schedules)}
  end

  @doc """
  The callee has opened the call page: the ring is answered. Tells the
  caller's side (locally or over federation) so it starts WebRTC
  negotiation — the caller never sends an offer into the void.
  """
  def join_call(%User{id: user_id} = user, public_id) do
    with {:ok, %Call{callee_id: ^user_id, state: "ringing"} = call} <- get_call(user, public_id) do
      call = set_state(call, "accepted")
      broadcast(call, {:call_peer_joined, call.public_id})

      relay_to_remote_peer(call, user, fn authority ->
        Veejr.Federation.deliver_call_update(authority, call, "joined")
      end)

      {:ok, call}
    else
      {:ok, %Call{} = call} -> {:error, {:bad_state, call.state}}
      error -> error
    end
  end

  @doc "Joins a ringing call from its admitted temporary guest side."
  def join_guest_call(%GuestConference{} = conference) do
    with {:ok, %GuestCall{state: "ringing"} = call} <- get_guest_call(conference) do
      call = set_guest_state(call, "accepted")
      broadcast(call, {:call_peer_joined, call.public_id})
      {:ok, call}
    else
      {:ok, %GuestCall{} = call} -> {:error, {:bad_state, call.state}}
      error -> error
    end
  end

  @doc "Declines a ringing call (callee side)."
  def decline_call(%User{id: user_id} = user, public_id) do
    with {:ok, %Call{callee_id: ^user_id, state: "ringing"} = call} <- get_call(user, public_id) do
      call = set_state(call, "declined")
      broadcast(call, {:call_ended, call.public_id, "declined"})

      relay_to_remote_peer(call, user, fn authority ->
        Veejr.Federation.deliver_call_update(authority, call, "declined")
      end)

      {:ok, call}
    else
      {:ok, %Call{}} -> {:error, :not_ringing}
      error -> error
    end
  end

  @doc "Cancels an unanswered invitation from its caller side."
  def cancel_call(%User{id: user_id} = user, public_id) do
    with {:ok, %Call{caller_id: ^user_id, state: "ringing"} = call} <-
           get_call(user, public_id) do
      call = set_state(call, "cancelled")
      broadcast(call, {:call_ended, call.public_id, "cancelled"})
      notify_ring_cancelled(call)

      relay_to_remote_peer(call, user, fn authority ->
        Veejr.Federation.deliver_call_update(authority, call, "cancelled")
      end)

      {:ok, call}
    else
      {:ok, %Call{}} -> {:error, :not_ringing}
      error -> error
    end
  end

  @doc "Ends a call from either side: hang-up, or cancel while still ringing."
  def end_call(%User{} = user, public_id) do
    with {:ok, %Call{} = call} <- get_call(user, public_id) do
      if call.state in ["ringing", "accepted"] do
        final = if call.state == "ringing", do: "missed", else: "ended"
        call = set_state(call, final)
        broadcast(call, {:call_ended, call.public_id, final})

        relay_to_remote_peer(call, user, fn authority ->
          Veejr.Federation.deliver_call_update(authority, call, "ended")
        end)
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
  Relays one sealed signaling payload (offer/answer/ICE) to the peer. The
  payload is `nacl.box` ciphertext produced in the sender's browser — the
  server cannot read or alter it. Remote peers get it over the signed
  federation channel, in the background so a slow peer instance never
  blocks the sender's socket.
  """
  def signal(%User{id: user_id} = user, public_id, ciphertext, nonce)
      when is_binary(ciphertext) and is_binary(nonce) do
    with {:ok, %Call{state: "accepted"} = call} <- get_call(user, public_id) do
      broadcast(call, {:call_signal, call.public_id, user_id, ciphertext, nonce})

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

  @doc "Relays one sealed signaling payload from an authorized temporary guest."
  def signal_guest(%GuestConference{id: conference_id} = conference, ciphertext, nonce)
      when is_binary(ciphertext) and is_binary(nonce) do
    with {:ok, %GuestCall{state: "accepted"} = call} <- get_guest_call(conference) do
      broadcast(
        call,
        {:call_signal, call.public_id, {:guest, conference_id}, ciphertext, nonce}
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
      broadcast(call, {:call_signal, call.public_id, host.id, ciphertext, nonce})
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

        ring_local(%{call | caller: remote_caller, callee: local_callee}, local_callee)
        {:ok, :created}
    end
  end

  @doc "Applies a joined/declined/ended/disconnected update relayed by the remote instance."
  def receive_remote_update(public_id, verified_authority, event)
      when event in ["joined", "declined", "cancelled", "ended", "disconnected"] do
    with {:ok, call} <- remote_party_call(public_id, verified_authority) do
      case event do
        "joined" when call.state == "ringing" ->
          call = set_state(call, "accepted")
          broadcast(call, {:call_peer_joined, call.public_id})

        "declined" when call.state == "ringing" ->
          call = set_state(call, "declined")
          broadcast(call, {:call_ended, call.public_id, "declined"})

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
      broadcast(call, {:call_signal, call.public_id, remote.id, ciphertext, nonce})
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

  defp notify_ring_cancelled(%Call{callee: %User{host: nil, id: callee_id}} = call) do
    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      "user:#{callee_id}",
      {:veejr_call_cancelled, call.public_id}
    )
  end

  defp notify_ring_cancelled(%Call{}), do: :ok

  defp notify_schedule_created(%ScheduledCall{invitee: %User{host: nil}} = schedule),
    do: notify_schedule_user(schedule, schedule.invitee, :scheduled)

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
