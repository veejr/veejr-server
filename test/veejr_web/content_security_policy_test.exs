defmodule VeejrWeb.ContentSecurityPolicyTest do
  use VeejrWeb.ConnCase, async: true

  alias VeejrWeb.ContentSecurityPolicy

  defp policy_header(conn) do
    conn |> get_resp_header("content-security-policy") |> List.first()
  end

  defp directive(policy, name) do
    policy
    |> String.split("; ")
    |> Enum.find(&String.starts_with?(&1, name <> " "))
  end

  describe "browser responses" do
    test "carry an enforcing policy", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert policy = policy_header(conn)
      assert get_resp_header(conn, "content-security-policy-report-only") == []
      assert directive(policy, "default-src") == "default-src 'self'"
      assert directive(policy, "object-src") == "object-src 'none'"
      assert directive(policy, "base-uri") == "base-uri 'none'"
      assert directive(policy, "frame-ancestors") == "frame-ancestors 'none'"
      assert directive(policy, "form-action") == "form-action 'self'"
    end

    test "confine script and network traffic to this origin", %{conn: conn} do
      policy = conn |> get(~p"/") |> policy_header()

      # The point of the policy: injected script cannot run from another
      # origin, and a stolen key has nowhere off-origin to be sent.
      script = directive(policy, "script-src")
      assert script =~ "'self'"
      refute script =~ "'unsafe-inline'"
      refute script =~ "'unsafe-eval'"
      assert directive(policy, "connect-src") == "connect-src 'self'"
    end

    test "permit the embedded privacy-preserving YouTube host only", %{conn: conn} do
      policy = conn |> get(~p"/") |> policy_header()

      assert directive(policy, "frame-src") == "frame-src https://www.youtube-nocookie.com"
    end

    test "permit federated avatar and decrypted attachment sources", %{conn: conn} do
      policy = conn |> get(~p"/") |> policy_header()

      # Peer avatars are served from an origin that is not knowable in advance.
      assert directive(policy, "img-src") =~ "https:"
      assert directive(policy, "img-src") =~ "blob:"
      assert directive(policy, "media-src") =~ "blob:"
    end
  end

  describe "nonce" do
    test "authorises the inline theme bootstrap", %{conn: conn} do
      conn = get(conn, ~p"/")
      policy = policy_header(conn)

      assert [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)
      # The rendered page must carry the same nonce, or the theme script that
      # runs before first paint would be blocked.
      assert html_response(conn, 200) =~ ~s(nonce="#{nonce}")
    end

    test "is fresh for every response", %{conn: conn} do
      first = build_conn() |> get(~p"/") |> policy_header()
      second = build_conn() |> get(~p"/") |> policy_header()

      assert [_, first_nonce] = Regex.run(~r/'nonce-([^']+)'/, first)
      assert [_, second_nonce] = Regex.run(~r/'nonce-([^']+)'/, second)
      refute first_nonce == second_nonce
      # 16 random bytes, base64 encoded.
      assert byte_size(Base.decode64!(first_nonce)) == 16

      _ = conn
    end
  end

  describe "report-only mode" do
    test "swaps the header without changing the policy", %{conn: conn} do
      Application.put_env(:veejr, :csp_report_only, true)
      on_exit(fn -> Application.delete_env(:veejr, :csp_report_only) end)

      conn = get(conn, ~p"/")

      assert get_resp_header(conn, "content-security-policy") == []
      assert [reported] = get_resp_header(conn, "content-security-policy-report-only")
      assert reported =~ "default-src 'self'"
    end
  end

  describe "policy/1" do
    test "is a single well-formed header value" do
      policy = ContentSecurityPolicy.policy("abc123")

      refute policy =~ "\n"
      assert policy =~ "'nonce-abc123'"
      assert length(String.split(policy, "; ")) > 10
    end
  end
end
