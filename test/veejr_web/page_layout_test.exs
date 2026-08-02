defmodule VeejrWeb.PageLayoutTest do
  use Veejr.DataCase

  import Veejr.AccountsFixtures

  alias Veejr.Accounts
  alias VeejrWeb.PageLayout

  describe "set_page_layout/2" do
    test "accepts the two layouts and refuses anything else" do
      user = user_fixture()
      assert user.page_layout == "full"

      assert {:ok, user} = Accounts.set_page_layout(user, "simple")
      assert user.page_layout == "simple"

      assert {:ok, user} = Accounts.set_page_layout(user, "full")
      assert user.page_layout == "full"

      assert {:error, changeset} = Accounts.set_page_layout(user, "orbit")
      assert "is invalid" in errors_on(changeset).page_layout
    end
  end

  describe "messages_redirect/1" do
    test "carries the parameters the plain page understands" do
      assert PageLayout.messages_redirect(%{}) == "/messages/simple"

      assert PageLayout.messages_redirect(%{"conversation" => "abc"}) ==
               "/messages/simple?conversation=abc"

      assert PageLayout.messages_redirect(%{"friend_id" => "7"}) == "/messages/simple?friend=7"
    end

    test "stays on the full page for anything the plain page cannot show" do
      # Each of these names a capability the plain page does not have, so the
      # deep link wins over the preference rather than losing what was asked.
      assert PageLayout.messages_redirect(%{"self_notes" => "true"}) == nil
      assert PageLayout.messages_redirect(%{"group_id" => "3"}) == nil
      assert PageLayout.messages_redirect(%{"friend_ids" => "1,2"}) == nil
      assert PageLayout.messages_redirect(%{"conversation" => "abc", "group_id" => "3"}) == nil
    end
  end

  describe "route/2" do
    test "names where each surface lives" do
      assert PageLayout.route(:contacts, "simple") == "/contacts/simple"
      assert PageLayout.route(:contacts, "full") == "/contacts"
      assert PageLayout.route(:messages, "simple") == "/messages/simple"
      assert PageLayout.route(:messages, "full") == "/messages"
    end
  end
end
