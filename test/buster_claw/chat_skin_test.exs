defmodule BusterClaw.ChatSkinTest do
  # Writes app_settings rows through the shared Settings store.
  use BusterClaw.DataCase, async: true

  alias BusterClaw.ChatSkin
  alias BusterClaw.Settings

  describe "the catalog" do
    test "the default is a skin that exists, and is the first option" do
      # The dropdown renders `skins/0` in order and the operator's eye lands on
      # the top one; a default buried in the middle of the list would read as
      # though something else was selected.
      assert ChatSkin.default() in ChatSkin.keys()
      assert hd(ChatSkin.keys()) == ChatSkin.default()
    end

    test "every skin has a key, a label and a blurb" do
      for skin <- ChatSkin.skins() do
        assert is_binary(skin.key) and skin.key != ""
        assert is_binary(skin.label) and skin.label != ""
        assert is_binary(skin.blurb) and skin.blurb != ""
      end
    end

    test "keys/0 and skins/0 cannot drift" do
      assert ChatSkin.keys() == Enum.map(ChatSkin.skins(), & &1.key)
    end

    test "the three skins the operator asked for are the three that exist" do
      # Named rather than counted: this is the roadmap's scope, and a fourth skin
      # arriving should be a deliberate edit here, not a silent one.
      assert ChatSkin.keys() == ["industrial", "minimal", "slack"]
    end

    test "label/1 answers for a real skin and refuses to invent one" do
      assert ChatSkin.label("minimal") == "Minimal"
      assert ChatSkin.label("chartreuse") == nil
    end
  end

  describe "reading" do
    test "nothing stored is the default" do
      assert ChatSkin.get() == ChatSkin.default()
    end

    test "a stored skin round-trips" do
      assert {:ok, "slack"} = ChatSkin.set("slack")
      assert ChatSkin.get() == "slack"
      assert Settings.get(ChatSkin.setting_key()) == "slack"
    end

    test "a stored value that is not a skin resolves to the default" do
      # A hand-edited row, or a skin that existed in an older release and was
      # removed in this one. Either way the panel must not render unstyled.
      Settings.put(ChatSkin.setting_key(), "vaporwave")

      assert ChatSkin.get() == ChatSkin.default()
    end
  end

  describe "writing" do
    test "a skin that does not exist is refused, and nothing is stored" do
      assert {:error, :invalid_skin} = ChatSkin.set("vaporwave")
      assert Settings.get(ChatSkin.setting_key()) == nil
      assert ChatSkin.get() == ChatSkin.default()
    end

    test "a non-string is refused rather than crashing the caller" do
      assert {:error, :invalid_skin} = ChatSkin.set(nil)
      assert {:error, :invalid_skin} = ChatSkin.set(:minimal)
    end

    test "a change is announced to whoever is subscribed" do
      # This broadcast is the entire live-update path: an open homepage hears it
      # and re-renders `data-chat-skin`. Without it the operator would change the
      # dropdown and see nothing until a reload.
      ChatSkin.subscribe()

      assert {:ok, "minimal"} = ChatSkin.set("minimal")
      assert_receive {:chat_skin, "minimal"}
    end

    test "re-selecting the skin already in force still announces" do
      # Idempotent in storage, not in signalling. A dropdown that does nothing
      # visible on re-select reads as broken, and one cheap re-render is a better
      # trade than that ambiguity.
      ChatSkin.set("slack")
      ChatSkin.subscribe()

      assert {:ok, "slack"} = ChatSkin.set("slack")
      assert_receive {:chat_skin, "slack"}
    end

    test "a refused skin announces nothing" do
      ChatSkin.subscribe()

      assert {:error, :invalid_skin} = ChatSkin.set("vaporwave")
      refute_receive {:chat_skin, _}, 50
    end
  end
end
