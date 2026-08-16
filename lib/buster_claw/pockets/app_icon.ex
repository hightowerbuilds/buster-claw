defmodule BusterClaw.Pockets.AppIcon do
  @moduledoc """
  The icon macOS shows in the Dock while this app is running — as a Pocket.

  `APP_ICON_ROADMAP`. Drop an image into `pockets/app-icon/` and **nothing
  happens**; the operator applies it and only then does the Dock change. That gap
  is the whole feature, and it is the Phase 0 decision: an agent can write a file
  into a Pocket without any command at all, so a slot that simply follows its
  folder would hand an unattended run the app's identity in the OS chrome.

  ## Two icons, and this is the one that is safe to touch

  `NSApplication.applicationIconImage` — set at runtime, reverts on quit, touches
  no file. The **bundle** icon (`Contents/Resources/*.icns`) is sealed by the code
  signature and is not reachable from here on purpose: writing it would invalidate
  the Developer ID signature, the hardened runtime and the notarization ticket at
  once. So `:empty` means *make no call*, not *set the shipped PNG* — the bundle
  icon already is the default, and the absence of a call is how it shows.

  ## Applied is keyed to the bytes, not the filename

  The same answer `Appearance.ShaderApproval` gives, for the same reason: a name
  is forgeable. Recording "icon.png is applied" would let anything with write
  access to the Pocket swap the bytes underneath a choice the operator made about
  something else. So applying records a SHA-256, and `current_path/0` re-hashes
  every read. Replace the file and the Dock falls back to the shipped icon until
  the operator applies again — visible, recoverable, and not an icon they never
  chose.

  It is deliberately a second small store rather than a generalisation of
  `ShaderApproval`: that one maps many names to hashes and backfills; this is one
  slot with no history. Merging them would buy about ten lines and cost a shared
  abstraction neither shape wants yet.

  ## Not a `Pockets.Brand` slot

  Brand's slots render as `<img>` in the app's own chrome and carry a three-state
  model (`:default` / `:custom` / over-full → text label). This has a **fourth**
  state — a file present but not applied — no in-app rendering at all, and no text
  fallback available, because a Dock tile cannot render a label. Forcing it into
  that table would make the model wrong for six slots to accommodate a seventh.
  """

  alias BusterClaw.Pockets
  alias BusterClaw.Settings

  @pocket "app-icon"
  @approved_key "app_icon_applied_hash"
  @topic "brand:app_icon"

  # What macOS will load into an NSImage. Narrower than the Pocket serves, and
  # narrower than `Brand`'s list: no SVG, because `NSImage` does not read one.
  @image_exts ~w(.png .jpg .jpeg .gif .tiff .icns)

  @doc "The Pocket this reads. Fixed, never resolved by role — an agent writes manifests."
  def pocket, do: @pocket

  @doc "PubSub topic broadcast when the applied icon changes."
  def topic, do: @topic

  @doc """
  Create the Pocket on demand, with a manifest that explains the gap.

  On-demand rather than at install, per the workspace registry — and idempotent,
  so it never overwrites a manifest the operator has edited.
  """
  def ensure do
    Pockets.ensure_pocket(@pocket, %{
      kind: :icons,
      description: "Your own icon for the macOS Dock, while the app is running.",
      roles: [],
      body:
        "Put one image here, then apply it in Settings → Pockets. A file sitting " <>
          "in this folder is not the icon until you apply it, and replacing the " <>
          "file puts the shipped icon back until you apply again."
    })
  end

  @doc """
  What this slot is doing right now.

    * `:empty` — no image; the Dock shows the shipped icon
    * `:pending` — an image is here and has **not** been applied
    * `:applied` — the image is applied and its bytes still match
    * `:replaced` — applied once, but the file has changed since
    * `{:error, :too_many, n}` — more than one image; nothing is applied

  Derived from the directory and the file's current hash on every call, so there
  is no state to repair and no way for this to get stuck.
  """
  def status do
    case images() do
      [] ->
        :empty

      [one] ->
        cond do
          applied?(one) -> :applied
          is_nil(applied_hash()) -> :pending
          true -> :replaced
        end

      many ->
        {:error, :too_many, length(many)}
    end
  end

  @doc """
  The absolute path the native layer should load, or `nil` for the shipped icon.

  `nil` in every state except `:applied` — including `:replaced`, which is the
  point: an image the operator has not seen must not reach the Dock just because
  its predecessor was approved.
  """
  def current_path do
    case images() do
      [one] -> if applied?(one), do: file_path(one)
      _ -> nil
    end
  end

  @doc """
  Apply the image in this Pocket: record its current bytes and broadcast.

  `{:ok, path}` | `{:error, :no_image | {:too_many, n} | reason}`. The only place
  an icon is ever chosen — there is no command for it, at any tier.
  """
  def apply_icon do
    case images() do
      [one] ->
        with {:ok, hash} <- hash(one) do
          Settings.put(@approved_key, hash)
          broadcast()
          {:ok, file_path(one)}
        end

      [] ->
        {:error, :no_image}

      many ->
        {:error, {:too_many, length(many)}}
    end
  end

  @doc """
  Stop using a custom icon. The file stays; only the choice is withdrawn.

  Deleting the operator's image would be the app destroying something they made
  because they changed their mind about showing it — the same call `Brand` made
  when it moved replaced art instead of removing it.
  """
  def revoke do
    Settings.put(@approved_key, nil)
    broadcast()
    :ok
  end

  # --- internals ----------------------------------------------------------

  defp applied?(filename) do
    case {applied_hash(), hash(filename)} do
      {nil, _} -> false
      {stored, {:ok, current}} -> stored == current
      _ -> false
    end
  end

  defp applied_hash, do: Settings.get(@approved_key)

  defp hash(filename) do
    case File.read(file_path(filename)) do
      {:ok, bytes} -> {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_path(filename), do: Path.join(Pockets.pocket_dir(@pocket), filename)

  # Read through `Pockets.load/1` so the Pocket's own fences apply unchanged: a
  # planted symlink is skipped, subdirectories are skipped, and a Pocket whose
  # manifest is broken lists nothing.
  defp images do
    case Pockets.load(@pocket) do
      {:ok, pocket} ->
        pocket
        |> Pockets.contents()
        |> Enum.map(& &1.name)
        |> Enum.filter(&image?/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp image?(name), do: Path.extname(name) |> String.downcase() |> then(&(&1 in @image_exts))

  defp broadcast, do: Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, :app_icon_changed)
end
