defmodule BusterClaw.Sketch.PlacementTest do
  # Extracted from `SketchComponent` because Phase 3's `sketch_import` places an
  # image the same way a drop does. Tested here rather than through a LiveView,
  # which is most of the reason it moved.
  use ExUnit.Case, async: true

  alias BusterClaw.Sketch.Placement

  @max_bytes 10 * 1024 * 1024

  describe "fit/2" do
    test "a small image is left alone, never blown up to fill the box" do
      # `min(1.0, ...)` — the box is a ceiling, not a target.
      assert Placement.fit(40, 30) == {40.0, 30.0}
    end

    test "a large image is scaled to the longest side" do
      assert {w, h} = Placement.fit(2000, 1000)
      assert w == Placement.max_placed() / 1
      assert h == Placement.max_placed() / 2
    end

    test "aspect ratio survives, whichever side is longer" do
      # A distorted image is worse than a small one, so both axes take the same
      # scale — the bug this would have if width and height were fitted apart.
      #
      # RELATIVE tolerance, not absolute. Written with `assert_in_delta` on the
      # ratios first, which failed on 3000x17: coordinates round to one decimal
      # (matching `Element`), so a 2.38px side becomes 2.4 — 0.8%, and 1.4
      # absolute on a ratio of 176. The error scales with the ratio, so the
      # tolerance has to as well; the sub-percent distortion is inherent to
      # rounding and invisible on a sliver that thin.
      for {w, h} <- [{1179, 2556}, {2556, 1179}, {800, 800}, {3000, 17}] do
        {fw, fh} = Placement.fit(w, h)
        error = abs(fw / fh - w / h) / (w / h)

        assert error < 0.01, "#{w}x#{h} came back distorted by #{Float.round(error * 100, 2)}%"
        assert fw <= Placement.max_placed() and fh <= Placement.max_placed()
      end
    end
  end

  describe "origin/2" do
    test "an image is centred on the point, not hung from it" do
      # You point at where you want the picture, not at where its top-left
      # corner should be.
      assert Placement.origin({300, 200}, {100, 60}) == {250.0, 170.0}
    end

    test "a drop near an edge does not put most of the image off the paper" do
      assert Placement.origin({10, 5}, {200, 100}) == {0.0, 0.0}
    end
  end

  describe "humanize/3" do
    test "each refusal gets its own sentence" do
      for reason <- [:too_large, :unsupported, :empty, :not_found, :not_a_file, :too_many] do
        sentence = Placement.humanize(reason, @max_bytes, 5)

        assert is_binary(sentence) and sentence != ""
        refute sentence =~ "could not be read", "#{reason} fell through to the generic sentence"
      end
    end

    test "the size limit is quoted from the caller, not hardcoded twice" do
      assert Placement.humanize(:too_large, @max_bytes, 5) =~ "10 MB"
      assert Placement.humanize(:too_large, 5 * 1024 * 1024, 5) =~ "5 MB"
    end

    test "the hook's string reasons read the same as the server's atoms" do
      # The dropzone refuses on the client and sends the reason back, so one
      # sentence comes back however the file was refused.
      assert Placement.humanize("too_large", @max_bytes, 5) ==
               Placement.humanize(:too_large, @max_bytes, 5)

      assert Placement.humanize("unsupported_type", @max_bytes, 5) =~ "PNG"
    end

    test "an unrecognised reason does not mint an atom" do
      # A crafted payload must not reach the atom table.
      #
      # Asserted on THIS atom rather than on `:erlang.system_info(:atom_count)`,
      # which was the first attempt and is not a per-test measurement: the suite
      # is async, so a concurrent test minting one fails this for reasons that
      # have nothing to do with the code under test.
      reason = "wat_#{System.unique_integer([:positive])}"

      assert Placement.humanize(reason, @max_bytes, 5) == "it could not be read"

      assert_raise ArgumentError, fn -> String.to_existing_atom(reason) end
    end

    test "a non-string, non-atom reason still produces a sentence" do
      assert Placement.humanize({:weird, 1}, @max_bytes, 5) == "it could not be read"
    end
  end
end
