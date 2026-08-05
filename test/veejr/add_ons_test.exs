defmodule Veejr.AddOnsTest do
  use Veejr.DataCase

  import Veejr.AccountsFixtures

  alias Veejr.{AddOns, Admin, InstanceSettings}

  test "a new instance offers nothing and would roll fair dice" do
    settings = InstanceSettings.get()

    refute settings.craps_enabled
    assert settings.craps_dice_mode == "fair"

    refute AddOns.enabled?(:craps)
    assert AddOns.enabled() == []
    assert AddOns.enabled_ids() == []
    assert AddOns.craps_dice_mode() == "fair"
  end

  test "an administrator turns craps on and it keeps the fair dice default" do
    admin = user_fixture()

    assert {:ok, settings} = Admin.update_instance_settings(admin, %{"craps_enabled" => "true"})
    assert settings.craps_enabled
    assert settings.craps_dice_mode == "fair"

    assert AddOns.enabled?(:craps)
    assert AddOns.enabled_ids() == [:craps]
    assert [%{id: :craps, path: "/craps", trust: :refereed}] = AddOns.enabled()
  end

  test "only an administrator may change add-ons" do
    _admin = user_fixture()
    member = user_fixture()

    assert {:error, :unauthorized} =
             Admin.update_instance_settings(member, %{"craps_enabled" => "true"})

    refute AddOns.enabled?(:craps)
  end

  test "the house edge is available but has to be chosen deliberately" do
    admin = user_fixture()

    assert {:ok, settings} =
             Admin.update_instance_settings(admin, %{
               "craps_enabled" => "true",
               "craps_dice_mode" => "house"
             })

    assert settings.craps_dice_mode == "house"
    assert AddOns.craps_dice_mode() == "house"
  end

  test "an unrecognized dice mode is refused" do
    admin = user_fixture()

    assert {:error, changeset} =
             Admin.update_instance_settings(admin, %{"craps_dice_mode" => "loaded"})

    assert "is invalid" in errors_on(changeset).craps_dice_mode
    assert AddOns.craps_dice_mode() == "fair"
  end

  test "turning an add-on on and off is recorded in the audit log" do
    admin = user_fixture()

    {:ok, _settings} = Admin.update_instance_settings(admin, %{"craps_enabled" => "true"})

    assert Enum.any?(Admin.list_audit_events(), fn event ->
             event.action == "instance.settings_updated" and
               "craps_enabled" in event.details["fields"]
           end)
  end

  describe "an administrator setting a stack" do
    test "replenishes a player who has gone bust" do
      admin = user_fixture()
      player = user_fixture()
      AddOns.Craps.put_chip_balance(player.id, 0)

      assert {:ok, ^player} = Admin.set_craps_chips(admin, player.id, 1000)
      assert AddOns.Craps.chip_balance(player) == 1000
    end

    test "can set any amount up to the cap, including zero" do
      admin = user_fixture()
      player = user_fixture()

      assert {:ok, _} = Admin.set_craps_chips(admin, player.id, 0)
      assert AddOns.Craps.chip_balance(player) == 0

      assert {:ok, _} = Admin.set_craps_chips(admin, player.id, Admin.max_craps_chips())
      assert AddOns.Craps.chip_balance(player) == Admin.max_craps_chips()
    end

    test "refuses a slipped keystroke rather than minting a fortune" do
      admin = user_fixture()
      player = user_fixture()

      assert {:error, :invalid_amount} =
               Admin.set_craps_chips(admin, player.id, Admin.max_craps_chips() + 1)

      assert {:error, :invalid_amount} = Admin.set_craps_chips(admin, player.id, -50)
      assert AddOns.Craps.chip_balance(player) == 0
    end

    test "only an administrator may do it" do
      _admin = user_fixture()
      member = user_fixture()
      player = user_fixture()

      assert {:error, :unauthorized} = Admin.set_craps_chips(member, player.id, 5000)
      assert AddOns.Craps.chip_balance(player) == 0
    end

    test "a stranger's account is not ours to top up" do
      admin = user_fixture()

      assert {:error, :not_found} = Admin.set_craps_chips(admin, -1, 1000)
    end

    test "it goes in the audit log with the amount" do
      admin = user_fixture()
      player = user_fixture()

      {:ok, _} = Admin.set_craps_chips(admin, player.id, 2500)

      assert Enum.any?(Admin.list_audit_events(), fn event ->
               event.action == "craps.chips_set" and
                 event.target_id == player.id and
                 event.details["chips"] == 2500
             end)
    end
  end

  test "enabled? is false for an add-on that is not in the catalogue" do
    refute AddOns.enabled?(:roulette)
    assert AddOns.get(:roulette) == nil
  end
end
