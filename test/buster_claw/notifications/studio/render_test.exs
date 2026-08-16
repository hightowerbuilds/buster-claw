defmodule BusterClaw.Notifications.Studio.RenderTest do
  @moduledoc """
  The mixdown, and the effect chain on the way through.

  Extracted from `SoundStudioComponent` on 08-16, which is what made these
  testable at all — the render used to need a mounted LiveView.
  """
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.Studio.Effects
  alias BusterClaw.Notifications.Studio.Render
  alias BusterClaw.Notifications.StudioMix

  setup do
    root = Path.join(System.tmp_dir!(), "bc_render_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    File.mkdir_p!(SoundStudio.dir())

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # A source on disk, and a resolver that finds it the way the sidebar would.
  defp source(name, samples) do
    data = Enum.reduce(samples, <<>>, fn s, acc -> acc <> <<s::little-signed-16>> end)
    clip = %SoundStudio{sample_rate: 22_050, channels: 1, bits: 16, data: data}
    path = Path.join(SoundStudio.dir(), name)
    :ok = SoundStudio.write(clip, path)
    name
  end

  defp resolver do
    fn name ->
      path = Path.join(SoundStudio.dir(), name)
      if File.regular?(path), do: %{path: path}, else: nil
    end
  end

  defp mix_with(clips) do
    mix = StudioMix.new("test")
    [track | _] = mix.tracks

    Enum.reduce(clips, mix, fn {name, start_ms, duration}, acc ->
      StudioMix.add_clip(acc, track.id, name, start_ms, duration)
    end)
  end

  defp samples(%SoundStudio{data: data}), do: for(<<s::little-signed-16 <- data>>, do: s)

  describe "refusals" do
    test "an empty mix is refused, and says which emptiness it was" do
      assert {:error, :empty_mix} = Render.mixdown(StudioMix.new("test"), resolver())
    end

    test "clips that exist but are all silenced is a DIFFERENT refusal" do
      source("a.wav", [100, 200])
      mix = mix_with([{"a.wav", 0, 90}])
      [track | _] = mix.tracks
      muted = StudioMix.toggle_mute(mix, track.id)

      # Not :empty_mix — an arrangement you silenced is a different mistake from
      # one you never filled, and deserves a different sentence.
      assert {:error, :all_silenced} = Render.mixdown(muted, resolver())
    end

    test "a missing source refuses the WHOLE render rather than dropping a layer" do
      source("a.wav", [100, 200])
      mix = mix_with([{"a.wav", 0, 90}, {"gone.wav", 0, 90}])

      # A mix missing one layer still sounds finished, so skipping would ship a
      # loss the operator never learns about.
      assert {:error, :missing_source} = Render.mixdown(mix, resolver())
    end
  end

  describe "effects on the way through" do
    test "a clip's chain is applied BEFORE the sum, not to the mix" do
      source("a.wav", [1, 2, 3, 4])
      mix = mix_with([{"a.wav", 0, 200}])
      [clip] = Enum.map(StudioMix.clips(mix), fn {_t, c} -> c end)

      plain = Render.mixdown(mix, resolver())
      reversed = mix |> StudioMix.add_effect(clip.id, "reverse") |> Render.mixdown(resolver())

      assert {:ok, a} = plain
      assert {:ok, b} = reversed
      assert samples(a) == [1, 2, 3, 4]
      assert samples(b) == [4, 3, 2, 1]
    end

    test "reversing ONE clip does not reverse the arrangement" do
      source("a.wav", [1, 2])
      source("b.wav", [10, 20])

      mix = mix_with([{"a.wav", 0, 90}, {"b.wav", 90, 90}])
      first = mix |> StudioMix.clips() |> Enum.map(fn {_t, c} -> c end) |> hd()

      {:ok, out} = mix |> StudioMix.add_effect(first.id, "reverse") |> Render.mixdown(resolver())

      # `a` is reversed in place; `b` still lands after it.
      assert Enum.take(samples(out), 2) == [2, 1]
    end

    test "a chain that lengthens a clip does not move the next one" do
      source("a.wav", List.duplicate(6000, 2205))
      source("b.wav", [999])

      mix = mix_with([{"a.wav", 0, 100}, {"b.wav", 100, 10}])
      first = mix |> StudioMix.clips() |> Enum.map(fn {_t, c} -> c end) |> hd()

      {:ok, dry} = Render.mixdown(mix, resolver())
      {:ok, wet} = mix |> StudioMix.add_effect(first.id, "reverb") |> Render.mixdown(resolver())

      # The tail makes the render longer, and `b` keeps its offset — the overlap
      # is summed, which is what a tail does on a real desk.
      assert length(samples(wet)) > length(samples(dry))
    end
  end

  describe "preview" do
    test "renders ONE clip through its chain, using the same path as the mixdown" do
      source("a.wav", [1, 2, 3])
      mix = mix_with([{"a.wav", 500, 200}])
      [clip] = Enum.map(StudioMix.clips(mix), fn {_t, c} -> c end)

      chained = StudioMix.add_effect(mix, clip.id, "reverse")
      effected = StudioMix.find_clip(chained, clip.id)

      assert {:ok, audio} = Render.preview(effected, resolver())
      assert samples(audio) == [3, 2, 1]
    end

    test "ignores the clip's offset — a preview is the sound, not its place" do
      source("a.wav", [7, 8])
      mix = mix_with([{"a.wav", 9_999, 90}])
      [clip] = Enum.map(StudioMix.clips(mix), fn {_t, c} -> c end)

      assert {:ok, audio} = Render.preview(clip, resolver())
      assert samples(audio) == [7, 8]
    end

    test "a missing source is refused rather than previewed as silence" do
      mix = mix_with([{"gone.wav", 0, 90}])
      [clip] = Enum.map(StudioMix.clips(mix), fn {_t, c} -> c end)

      assert {:error, :missing_source} = Render.preview(clip, resolver())
    end
  end

  describe "the chain survives the mix file" do
    test "effects round-trip through save and load, params included" do
      source("a.wav", [1, 2, 3])
      {:ok, "round-trip"} = StudioMix.create("round-trip")
      {:ok, mix} = StudioMix.load("round-trip")
      [track | _] = mix.tracks

      mix =
        mix
        |> StudioMix.add_clip(track.id, "a.wav", 0, 90)
        |> then(fn m ->
          [clip] = Enum.map(StudioMix.clips(m), fn {_t, c} -> c end)

          m
          |> StudioMix.add_effect(clip.id, "reverb")
          |> StudioMix.put_effect_param(clip.id, 0, "mix", 0.75)
          |> StudioMix.add_effect(clip.id, "reverse")
        end)

      :ok = StudioMix.save(mix)
      {:ok, reloaded} = StudioMix.load("round-trip")

      [clip] = Enum.map(StudioMix.clips(reloaded), fn {_t, c} -> c end)
      chain = StudioMix.chain(clip)

      assert Enum.map(chain, & &1.type) == ["reverb", "reverse"]
      assert hd(chain).params["mix"] == 0.75
    end

    test "a mix written before effects existed still opens" do
      # Every mix on disk before 08-16 has clips with no `effects` key at all.
      {:ok, "legacy"} = StudioMix.create("legacy")
      {:ok, mix} = StudioMix.load("legacy")
      [track | _] = mix.tracks
      mix = StudioMix.add_clip(mix, track.id, "a.wav", 0, 90)
      :ok = StudioMix.save(mix)

      path = Path.join(StudioMix.dir(), "legacy.mix.json")
      raw = path |> File.read!() |> Jason.decode!()

      stripped =
        update_in(raw, ["tracks"], fn tracks ->
          Enum.map(tracks, fn t ->
            update_in(t, ["clips"], fn cs -> Enum.map(cs, &Map.delete(&1, "effects")) end)
          end)
        end)

      File.write!(path, Jason.encode!(stripped))

      assert {:ok, reloaded} = StudioMix.load("legacy")
      [clip] = Enum.map(StudioMix.clips(reloaded), fn {_t, c} -> c end)
      assert StudioMix.chain(clip) == []
    end

    test "an effect naming a type that does not exist is DROPPED, not fatal" do
      {:ok, "hand-edited"} = StudioMix.create("hand-edited")
      {:ok, mix} = StudioMix.load("hand-edited")
      [track | _] = mix.tracks
      mix = StudioMix.add_clip(mix, track.id, "a.wav", 0, 90)
      :ok = StudioMix.save(mix)

      path = Path.join(StudioMix.dir(), "hand-edited.mix.json")
      raw = path |> File.read!() |> Jason.decode!()

      poisoned =
        update_in(raw, ["tracks"], fn tracks ->
          Enum.map(tracks, fn t ->
            update_in(t, ["clips"], fn cs ->
              Enum.map(cs, &Map.put(&1, "effects", [%{"type" => "teleport", "params" => %{}}]))
            end)
          end)
        end)

      File.write!(path, Jason.encode!(poisoned))

      assert {:ok, reloaded} = StudioMix.load("hand-edited")
      [clip] = Enum.map(StudioMix.clips(reloaded), fn {_t, c} -> c end)
      assert StudioMix.chain(clip) == []
    end

    test "a param written out of range is clamped on the way IN" do
      {:ok, "shouty"} = StudioMix.create("shouty")
      {:ok, mix} = StudioMix.load("shouty")
      [track | _] = mix.tracks
      mix = StudioMix.add_clip(mix, track.id, "a.wav", 0, 90)
      [clip] = Enum.map(StudioMix.clips(mix), fn {_t, c} -> c end)

      :ok = mix |> StudioMix.add_effect(clip.id, "gain") |> StudioMix.save()

      path = Path.join(StudioMix.dir(), "shouty.mix.json")
      raw = path |> File.read!() |> Jason.decode!()

      shouted =
        update_in(raw, ["tracks"], fn tracks ->
          Enum.map(tracks, fn t ->
            update_in(t, ["clips"], fn cs ->
              Enum.map(cs, fn c ->
                Map.put(c, "effects", [%{"type" => "gain", "params" => %{"amount" => 500}}])
              end)
            end)
          end)
        end)

      File.write!(path, Jason.encode!(shouted))

      {:ok, reloaded} = StudioMix.load("shouty")
      [reloaded_clip] = Enum.map(StudioMix.clips(reloaded), fn {_t, c} -> c end)

      {_min, max, _default} = Effects.entry("gain").params["amount"]
      assert hd(StudioMix.chain(reloaded_clip)).params["amount"] == max
    end
  end
end
