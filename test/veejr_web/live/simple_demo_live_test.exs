defmodule VeejrWeb.SimpleDemoLiveTest do
  use VeejrWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "mounts publicly with sample contacts", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/demo/simple")

    assert has_element?(view, "#simple-demo")
    assert has_element?(view, "#demo-contacts-screen")
    assert has_element?(view, "#demo-contact-maya", "Maya Chen")
  end

  test "filters contacts by name or handle", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/demo/simple")

    view
    |> form("#demo-search-form", search: %{query: "@jules"})
    |> render_change()

    assert has_element?(view, "#demo-contact-jules")
    refute has_element?(view, "#demo-contact-maya")
  end

  test "opens a conversation and sends a sample message", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/demo/simple")

    view |> element("#demo-contact-maya") |> render_click()

    assert has_element?(view, "#demo-conversation-screen")
    assert has_element?(view, "#demo-message-maya-1")

    view
    |> form("#demo-message-form", message: %{body: "See you there!"})
    |> render_submit()

    assert has_element?(view, "#demo-messages [data-message-mine='true']", "See you there!")
  end

  test "opens and closes the call dialog", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/demo/simple")

    view |> element("#demo-contact-maya") |> render_click()
    view |> element("#demo-call") |> render_click()

    assert has_element?(view, "#demo-call-dialog[role='dialog']")
    assert has_element?(view, "#demo-call-title", "Maya Chen")

    view |> element("#demo-call-cancel") |> render_click()
    refute has_element?(view, "#demo-call-dialog")
  end
end
