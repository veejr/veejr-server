defmodule Veejr.Calls.Notifier do
  @moduledoc """
  Email delivery for persisted scheduled calls.

  Only local users are emailed. Federated schedules are mirrored, so each
  participant's home instance sends mail to its own user without sharing email
  addresses between instances.
  """

  import Swoosh.Email

  alias Veejr.Accounts.User
  alias Veejr.Calls.ScheduledCall
  alias Veejr.Mailer

  def deliver_invitation(
        %ScheduledCall{invitee: %User{host: nil} = invitee, organizer: organizer} = schedule
      ) do
    organizer_name = display_name(organizer)

    deliver(
      invitee,
      "scheduled_call_invitation",
      "#{organizer_name} scheduled a call with you",
      """

      ==============================

      Hi #{display_name(invitee)},

      #{organizer_name} scheduled a private call with you for
      #{scheduled_time(schedule)}.

      Times in email are shown in UTC. Open Calls to see the time in your
      current device time zone and review the call notes:

      #{calls_url()}

      You will receive another email two minutes before the call.

      ==============================
      """
    )
  end

  def deliver_invitation(%ScheduledCall{}), do: :ok

  def deliver_two_minute_reminder(
        %ScheduledCall{} = schedule,
        %User{host: nil} = recipient
      ) do
    peer =
      if recipient.id == schedule.organizer_id,
        do: schedule.invitee,
        else: schedule.organizer

    deliver(
      recipient,
      "scheduled_call_two_minute_reminder",
      "Your call with #{display_name(peer)} starts in two minutes",
      """

      ==============================

      Hi #{display_name(recipient)},

      Your private call with #{display_name(peer)} is scheduled for
      #{scheduled_time(schedule)}.

      It starts in about two minutes. Open Calls to review the call notes and
      join when the organizer starts it:

      #{calls_url()}

      ==============================
      """
    )
  end

  def deliver_two_minute_reminder(%ScheduledCall{}, %User{}), do: :ok

  defp deliver(recipient, operation, subject, body) do
    email =
      new()
      |> to(recipient.email)
      |> from(Veejr.InstanceSettings.mail_from())
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        {:ok, email}

      {:error, reason} = error ->
        sanitized_reason = reason |> inspect() |> String.replace(recipient.email, "[REDACTED]")
        Veejr.Operations.record_failure("email", operation, sanitized_reason)
        error
    end
  end

  defp display_name(user), do: user.display_name || "@#{user.username}"

  defp scheduled_time(schedule) do
    Calendar.strftime(schedule.scheduled_for, "%B %d, %Y at %H:%M UTC")
  end

  defp calls_url, do: VeejrWeb.Endpoint.url() <> "/calls"
end
