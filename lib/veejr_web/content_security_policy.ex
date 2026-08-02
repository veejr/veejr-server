defmodule VeejrWeb.ContentSecurityPolicy do
  @moduledoc """
  Emits a Content-Security-Policy for browser responses.

  `docs/ARCHITECTURE.md` states the residual risk plainly: a malicious or
  compromised server can alter the JavaScript client and capture passphrases,
  keys, or plaintext. Encryption cannot fix that, because the server ships the
  code that does the encrypting.

  A CSP does not fix it either — an attacker who can rewrite `app.js` can
  usually rewrite this header too. What it does buy is a meaningful reduction
  in the *partial* compromises that stop short of full server control: a stored
  or reflected injection, a compromised dependency, a mistaken `raw/1`. Under
  this policy such a foothold cannot execute inline script and cannot exfiltrate
  a key to an off-origin endpoint, because `script-src` and `connect-src` are
  both pinned to this origin.

  ## Nonces

  The theme bootstrap in `root.html.heex` must run before first paint to avoid
  a flash of the wrong theme, so it stays inline and is authorized by a
  per-response nonce rather than by `'unsafe-inline'`. The nonce is 128 bits
  from `:crypto.strong_rand_bytes/1`, generated per response, and exposed to
  the layout as `@csp_nonce`.

  LiveView colocated hooks (`<script :type={Phoenix.LiveView.ColocatedHook}>`)
  are extracted into the bundle at compile time and never reach the browser as
  inline script, so they need no nonce.

  ## Why each directive is what it is

    * `script-src 'self' 'nonce-…'` — the bundle plus the theme bootstrap.
    * `style-src 'self' 'unsafe-inline'` — Tailwind ships as a file, but
      DaisyUI themes and several hooks set inline style attributes. Inline
      style is not a script-execution primitive; keeping it is a deliberate
      trade rather than an oversight.
    * `img-src 'self' data: blob: https:` — avatars are served by a *federated
      peer's* origin, which is not knowable ahead of time, so images cannot be
      pinned to `'self'`. `data:`/`blob:` cover decrypted attachments rendered
      client-side.
    * `media-src 'self' blob:` — decrypted audio/video play from object URLs.
    * `connect-src 'self'` — the load-bearing one. All application traffic is
      same-origin (LiveView socket, uploads, capability fetches), so a
      successful injection has nowhere to send a stolen key. WebRTC is not
      governed by `connect-src`, so STUN/TURN keep working.
    * `frame-src` — the two YouTube hosts watch parties and in-call shared
      viewing embed. `youtube-nocookie.com` is what loads; `youtube.com` is
      only ever reached by a viewer who asks for it, because YouTube's
      "confirm you're not a bot" check wants a signed-in session and the
      privacy host is a separate origin that can never carry one. Both are
      video frames from the same operator, so the policy's job — keeping an
      injection from framing an attacker's page — is unchanged.
    * `worker-src 'self'` — the Web Push service worker at `/sw.js`.
    * `object-src 'none'`, `base-uri 'none'`, `frame-ancestors 'none'` — remove
      plugin embedding, base-tag hijacking, and clickjacking.
    * `form-action 'self'` — a form cannot be repointed at another origin.

  ## Rollout

  A CSP that is slightly too strict breaks the application, and this instance
  ships continuously to live users. `:csp_report_only` therefore switches
  between `Content-Security-Policy-Report-Only` (observe, never block) and the
  enforcing header, so an operator can watch console reports for a release
  before enforcing. It defaults to enforcing; see `docs/OPERATIONS.md`.
  """

  import Plug.Conn

  @behaviour Plug

  @youtube_hosts "https://www.youtube-nocookie.com https://www.youtube.com"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = generate_nonce()

    # put_secure_browser_headers/2 ships its own minimal
    # "base-uri 'self'; frame-ancestors 'self'" policy. Drop it first so this
    # module is the single source of the page's policy — otherwise report-only
    # mode would still enforce Phoenix's default alongside the observed one.
    conn
    |> delete_resp_header("content-security-policy")
    |> assign(:csp_nonce, nonce)
    |> put_resp_header(header_name(), policy(nonce))
  end

  @doc "The policy string, exposed for tests and documentation."
  def policy(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob: https:",
      "media-src 'self' blob:",
      "font-src 'self' data:",
      "connect-src 'self'",
      "frame-src #{@youtube_hosts}",
      "worker-src 'self'",
      "manifest-src 'self'",
      "object-src 'none'",
      "base-uri 'none'",
      "form-action 'self'",
      "frame-ancestors 'none'"
    ]
    |> Enum.join("; ")
  end

  @doc "True when the policy is being observed rather than enforced."
  def report_only? do
    Application.get_env(:veejr, :csp_report_only, false)
  end

  defp header_name do
    if report_only?(), do: "content-security-policy-report-only", else: "content-security-policy"
  end

  defp generate_nonce do
    16 |> :crypto.strong_rand_bytes() |> Base.encode64()
  end
end
