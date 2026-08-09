defmodule BusterClaw.ChatTextSizeTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.ChatTextSize
  alias BusterClaw.Settings

  describe "the catalog" do
    test "the default is a real size, is first, and is exactly 1.0" do
      # Scale 1 is what makes the default need no CSS at all: the `var()` fallback
      # already resolves to it. If the default ever stopped being 1.0, the
      # stylesheet would have to grow a rule for it and the "out of the box
      # reading cannot regress" argument would go with it.
      assert ChatTextSize.default() in ChatTextSize.keys()
      assert hd(ChatTextSize.keys()) == ChatTextSize.default()
      assert hd(ChatTextSize.sizes()).scale == 1.0
    end

    test "the sizes only ever get larger, in order" do
      # Enlargement only, and monotonic — a dropdown reading Normal / Larger /
      # Large would be a bug nobody would report, they would just distrust it.
      scales = Enum.map(ChatTextSize.sizes(), & &1.scale)

      assert scales == Enum.sort(scales)
      assert Enum.uniq(scales) == scales
      assert Enum.all?(scales, &(&1 >= 1.0))
    end

    test "every size has a key, a label and a scale" do
      for size <- ChatTextSize.sizes() do
        assert is_binary(size.key) and size.key != ""
        assert is_binary(size.label) and size.label != ""
        assert is_float(size.scale)
      end
    end

    test "percent/1 is the number the dropdown shows, and is whole" do
      assert ChatTextSize.percent("normal") == 100
      assert ChatTextSize.percent("large") == 115
      assert ChatTextSize.percent("largest") == 150
      assert ChatTextSize.percent("enormous") == nil

      for size <- ChatTextSize.sizes() do
        assert ChatTextSize.percent(size.key) == round(size.scale * 100)
      end
    end
  end

  describe "reading and writing" do
    test "nothing stored is the default" do
      assert ChatTextSize.get() == ChatTextSize.default()
    end

    test "a stored size round-trips" do
      assert {:ok, "larger"} = ChatTextSize.set("larger")
      assert ChatTextSize.get() == "larger"
      assert Settings.get(ChatTextSize.setting_key()) == "larger"
    end

    test "a stored value that is not a size resolves to the default" do
      Settings.put(ChatTextSize.setting_key(), "gigantic")

      assert ChatTextSize.get() == ChatTextSize.default()
    end

    test "a size that does not exist is refused, and nothing is stored" do
      assert {:error, :invalid_size} = ChatTextSize.set("gigantic")
      assert {:error, :invalid_size} = ChatTextSize.set(nil)
      assert {:error, :invalid_size} = ChatTextSize.set(:large)
      assert Settings.get(ChatTextSize.setting_key()) == nil
    end

    test "a change is announced, and a refusal is not" do
      ChatTextSize.subscribe()

      assert {:ok, "large"} = ChatTextSize.set("large")
      assert_receive {:chat_text_size, "large"}

      assert {:error, :invalid_size} = ChatTextSize.set("gigantic")
      refute_receive {:chat_text_size, _}, 50
    end

    test "the size and the skin are independent settings" do
      # The whole point of two axes: choosing bigger text must not cost you the
      # look you picked.
      BusterClaw.ChatSkin.set("minimal")
      ChatTextSize.set("largest")

      assert BusterClaw.ChatSkin.get() == "minimal"
      assert ChatTextSize.get() == "largest"

      BusterClaw.ChatSkin.set("slack")

      assert ChatTextSize.get() == "largest"
    end
  end
end
