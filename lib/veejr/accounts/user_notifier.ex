defmodule Veejr.Accounts.UserNotifier do
  import Swoosh.Email

  alias Veejr.Mailer
  alias Veejr.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, operation, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Veejr.InstanceSettings.mail_from())
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        {:ok, email}

      {:error, reason} = error ->
        sanitized_reason = reason |> inspect() |> String.replace(recipient, "[REDACTED]")
        Veejr.Operations.record_failure("email", operation, sanitized_reason)
        error
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "email_change", "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  @doc "Notifies an inviter after someone accepts their invitation."
  def deliver_invitation_accepted(inviter, invited_user) do
    invited_name = invited_user.display_name || "@#{invited_user.username}"

    deliver(
      inviter.email,
      "invitation_accepted",
      "#{invited_name} joined #{Veejr.instance_name()}",
      """

      ==============================

      Hi #{inviter.display_name || "@#{inviter.username}"},

      #{invited_name} accepted your invitation and joined #{Veejr.instance_name()}.
      You are now connected as friends.

      ==============================
      """
    )
  end

  @doc "Emails a capability link for one immediate host-admitted guest call."
  def deliver_guest_conference_invitation(host, recipient, url) do
    host_name = host.display_name || "@#{host.username}"

    deliver(
      recipient,
      "guest_conference_invitation",
      "#{host_name} invited you to a private video call",
      """

      ==============================

      #{host_name} invited you to a private video call on #{Veejr.instance_name()}.

      You do not need an account. Open the link, enter your name, check your
      camera and microphone, and wait for #{host_name} to admit you:

      #{url}

      This single-use invitation expires in two hours. If you were not
      expecting it, you can safely ignore this email.

      ==============================
      """
    )
  end

  @doc "Emails a capability link for one seat at the craps table."
  def deliver_craps_guest_invitation(host, recipient, url) do
    host_name = host.display_name || "@#{host.username}"

    deliver(
      recipient,
      "craps_guest_invitation",
      "#{host_name} invited you to a game of craps",
      """

      ==============================

      #{host_name} invited you to play craps on #{Veejr.instance_name()}.

      You do not need an account. Open the link, pick a name, and sit down:

      #{url}

      The chips are play money. There is nothing to buy and nothing to cash
      out, and your stack only lasts as long as the table does.

      This invitation is yours alone and expires in a day. If you were not
      expecting it, you can safely ignore this email.

      ==============================
      """
    )
  end

  @doc "Emails a private capability link for one active YouTube watch party."
  def deliver_guest_watch_party_invitation(host, recipient, url) do
    host_name = host.display_name || "@#{host.username}"

    deliver(
      recipient,
      "guest_watch_party_invitation",
      "#{host_name} invited you to a YouTube watch party",
      """

      ==============================

      #{host_name} invited you to watch YouTube together on #{Veejr.instance_name()}.

      You do not need a Veejr account. Open this private link while the party
      is active:

      #{url}

      The link grants access only to this watch party and stops working when
      the host ends it. If you were not expecting it, you can safely ignore
      this email.

      ==============================
      """
    )
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "login_link", "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "account_confirmation", "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc "Sends a content-free delivery test to the instance administrator."
  def deliver_admin_test(%User{} = admin) do
    deliver(admin.email, "admin_delivery_test", "Veejr email delivery test", """

    This is a test email from #{Veejr.instance_name()}.

    Email delivery is configured and working.
    """)
  end
end
