defmodule BusterClaw.Pockets.Brand do
  @moduledoc """
  The app's own art, made swappable — the dock icons and the homepage banner.

  Each slot is backed by a Pocket the operator may put their own image in. The
  shipped art stays where it already is, **read-only in `priv/static`**, and is
  used whenever the operator has not supplied their own.

  Scoped as Part XI of `daily-growth/roadmaps/POCKETS_ROADMAP.md`.

  ## The three states, derived on every read

  | The Pocket | `status/1` | What renders |
  |---|---|---|
  | absent, or holds no image | `:default` | the shipped `priv/static` asset |
  | holds **exactly one** image | `:custom` | that image |
  | holds **two or more** | `{:error, :too_many, n}` | **the text label** |

  **Nothing is stored.** Every answer comes from listing the directory, so there
  is no repair action, no "revalidate", and no way for a slot to get stuck. Remove
  the extra file — in the app or in Finder — and the next render has the art back.

  ## Why over-full falls back to text, not to the shipped default

  This is the part that would be easy to get wrong, so it is written down.

  Picking the first image would **silently choose for the operator**, and the
  whole reason there is an error is that the app cannot know which one they meant.
  Falling back to the shipped default would **hide the problem entirely** — the
  dock would look right, the stray file would sit there forever, and the error
  message would be about nothing the operator can see.

  Text is the only fallback that looks different from *both* correct states. The
  art disappearing is the notification; the message only explains it.

  The dock already renders a label when an item has no image (`layouts.ex`, where
  Calendar has no PNG), so the failure state is behaviour that shipped long before
  this module.

  ## Replaced art is moved, not deleted

  Operator call (08-09). When an upload replaces a slot's image, the old one is
  **moved to the top level of the workspace**, not removed. It is a file the
  operator made or chose, and the app has no business destroying it because they
  picked a different one. `clear/1` does the same, for the same reason.

  A name already taken gets ` (1)`, ` (2)`, … — the collision rule
  `FileManager.import_file/4` already uses for dropped files. And a move that
  *fails* leaves the original where it is rather than deleting what it could not
  preserve; the Pocket then holds two images and the slot falls back to text,
  which is a state the operator can see and act on.

  ## One edge, stated rather than hidden

  A brand folder created **by hand with no `POCKET.md`** is inert: its images are
  not counted and the slot shows the shipped default.

  That is not an oversight. Serving goes through `Pockets.resolve/2`, which
  refuses a Pocket that does not load — so art in a manifest-less folder could be
  listed but never *served*, and honouring it would promise something the asset
  route would answer 404 to. The way in is "Add art", which writes the manifest
  (D12); after that, dropping files in from Finder behaves exactly as described
  above.

  ## Why the binding is a fixed name (roadmap D10)

  Role `nav_home` is filled by `pockets/nav-home/` and by nothing else.

  `BusterClaw.Pockets.for_role/1` finds whichever Pocket *declares* a role, and
  `POCKET.md` is a file the agent can write — so a discovered binding would let an
  agent shadow the app's own chrome by writing a manifest. Fixed names close that,
  and it is the same call already made for `backgrounds/`.

  ## Why cardinality lives here (roadmap D11)

  "Exactly one image" is a property of a dock slot, not a claim a Pocket makes
  about itself. A manifest saying `expects: 5` would be a permission wearing a
  description's clothes — the mistake caught once already with `source:` and
  `writable:`. So it is in `@slots` below, which the agent cannot reach.
  """

  alias BusterClaw.FileManager
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Pockets

  # role         — the slot's identity, used by callers
  # pocket       — the ONLY Pocket that may fill it (D10)
  # default      — the shipped asset under priv/static, never copied out (D13)
  # label        — what renders instead of art when the slot is in error
  # description  — seeded into POCKET.md on first upload, so the folder explains
  #                itself to whoever opens it in Finder
  @slots [
    %{
      role: "nav_home",
      pocket: "nav-home",
      default: "/images/brand/home-icon.png",
      label: "Home",
      description: "Your own Home icon for the dock."
    },
    %{
      role: "nav_workspace",
      pocket: "nav-workspace",
      default: "/images/brand/workspace-icon.png",
      label: "Workspace",
      description: "Your own Workspace icon for the dock."
    },
    %{
      role: "nav_browser",
      pocket: "nav-browser",
      default: "/images/brand/browser-icon.png",
      label: "Browser",
      description: "Your own Browser icon for the dock."
    },
    %{
      role: "nav_terminal",
      pocket: "nav-terminal",
      default: "/images/brand/terminal-icon.png",
      label: "Terminal",
      description: "Your own Terminal icon for the dock."
    },
    %{
      role: "nav_settings",
      pocket: "nav-settings",
      default: "/images/brand/settings-icon.png",
      label: "Settings",
      description: "Your own Settings icon for the dock."
    },
    %{
      role: "home_banner",
      pocket: "home-banner",
      default: "/images/brand/buster-claw-heading.png",
      label: "BusterClaw",
      description: "Your own banner for the top of the homepage."
    }
  ]

  # What counts as art. Deliberately narrower than the asset route serves: these
  # render in an <img> in the app's own chrome, so an unrenderable file in the
  # folder should read as a mistake rather than as a valid second image.
  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg)

  @doc """
  PubSub topic broadcast when any slot's art changes.

  Every LiveView renders the dock, and the homepage renders the banner, so a
  change has to reach surfaces that are not the one the operator uploaded on.
  `BusterClawWeb.ChromeHook` subscribes for all of them in one place.
  """
  def topic, do: "brand:art"

  @doc "Every brand slot, in display order."
  def slots, do: @slots

  @doc "The slot for `role`, or `nil`."
  def slot(role) when is_binary(role), do: Enum.find(@slots, &(&1.role == role))
  def slot(_role), do: nil

  @doc "Whether `name` is a Pocket this module owns."
  def brand_pocket?(name) when is_binary(name), do: Enum.any?(@slots, &(&1.pocket == name))
  def brand_pocket?(_name), do: false

  @doc """
  The state of one slot: `:default`, `:custom`, or `{:error, :too_many, count}`.

  See the moduledoc table. Derived from a directory listing every call.
  """
  def status(role) when is_binary(role) do
    case slot(role) do
      nil -> :default
      slot -> slot |> images() |> classify()
    end
  end

  def status(_role), do: :default

  @doc """
  The URL to render for `role`, or **`nil` when the slot is in error** — which is
  the signal to render the text label instead.

  Callers do not need to branch on `status/1`: a `nil` here already means "show
  the label", and every template that renders brand art already has that arm.
  """
  def image_url(role) when is_binary(role) do
    case slot(role) do
      nil ->
        nil

      slot ->
        case images(slot) do
          [one] -> custom_url(slot, one)
          [] -> slot.default
          _too_many -> nil
        end
    end
  end

  def image_url(_role), do: nil

  @doc "The text shown when a slot is in error."
  def label(role) do
    case slot(role) do
      nil -> ""
      slot -> slot.label
    end
  end

  @doc """
  Every slot with its current state, for the Pockets tab.

  `%{role, label, pocket, status, url, count}` — `url` is what renders now, and is
  `nil` exactly when `status` is an error.
  """
  def overview do
    Enum.map(@slots, fn slot ->
      files = images(slot)

      %{
        role: slot.role,
        label: slot.label,
        pocket: slot.pocket,
        description: slot.description,
        status: classify(files),
        url: image_url(slot.role),
        count: length(files)
      }
    end)
  end

  @doc """
  Put `src_path` into `role`'s Pocket as the art, replacing whatever is there.

  The sanctioned path (D12): an upload from inside the app leaves the Pocket with
  exactly one image, so it can never *create* the over-full state. Existing images
  are removed first — that is what makes this a replace rather than an addition,
  and it is why uploading is the way out of an over-full Pocket as well as the way
  into a custom one.

  Returns `{:ok, filename}` or `{:error, reason}`.
  """
  def put(role, src_path, client_name) when is_binary(role) do
    with {:ok, slot} <- fetch_slot(role),
         {:ok, ext} <- check_ext(client_name) do
      Pockets.ensure_pocket(slot.pocket, %{
        kind: :icons,
        description: slot.description,
        roles: [slot.role],
        body: "Put one image here. Two or more and the app shows a text label instead."
      })

      retire_all(slot)

      name = "#{slot.pocket}#{ext}"
      File.cp!(src_path, Path.join(Pockets.pocket_dir(slot.pocket), name))
      broadcast()
      {:ok, name}
    end
  end

  @doc """
  Drop the operator's art for `role`, returning the slot to the shipped default.

  Deletes the images in that Pocket and nothing else — the manifest and any notes
  the operator wrote stay, so the folder still explains itself.
  """
  def clear(role) when is_binary(role) do
    with {:ok, slot} <- fetch_slot(role) do
      retire_all(slot)
      broadcast()
      :ok
    end
  end

  @doc """
  Where a replaced image goes: the top level of the workspace.

  Operator call (08-09). Art that comes out of a brand Pocket is **moved, never
  deleted** — it is a file they made or chose, and the app has no business
  destroying it because they picked a different one.
  """
  def retirement_dir, do: Artifact.workspace_root()

  @doc "The upload extensions the picker accepts."
  def accepted_extensions, do: @image_exts

  # --- internals ----------------------------------------------------------

  defp fetch_slot(role) do
    case slot(role) do
      nil -> {:error, :unknown_role}
      slot -> {:ok, slot}
    end
  end

  defp check_ext(client_name) do
    ext = client_name |> to_string() |> Path.extname() |> String.downcase()
    if ext in @image_exts, do: {:ok, ext}, else: {:error, :unsupported_type}
  end

  # Move every image out of a slot's Pocket to the workspace root, keeping the
  # name and suffixing ` (n)` on a collision — the retired file is named for the
  # slot it came from (`nav-home.png`), which is more use to the operator later
  # than the name it arrived under.
  #
  # **A copy that fails leaves the original in place**, deliberately. The
  # alternative is deleting an image we could not preserve. The Pocket then holds
  # two images and the slot shows its text label — a visible state the operator
  # can act on, which is exactly what the over-full design is for.
  defp retire_all(slot) do
    dir = Pockets.pocket_dir(slot.pocket)
    root = retirement_dir()

    Enum.each(images(slot), fn name ->
      src = Path.join(dir, name)

      case FileManager.import_file(src, root, name, root) do
        {:ok, _target} -> File.rm(src)
        {:error, _reason} -> :ok
      end
    end)
  end

  defp broadcast do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, topic(), :brand_art_changed)
  end

  defp classify([_one]), do: :custom
  defp classify([]), do: :default
  defp classify(many), do: {:error, :too_many, length(many)}

  # The image filenames in a slot's Pocket, sorted.
  #
  # Reads through `Pockets.load/1` + `contents/1` rather than listing the
  # directory here, so the Pocket's own fences apply unchanged: a planted symlink
  # is skipped (not counted, and not renderable), subdirectories are skipped, and
  # a Pocket whose manifest is broken lists nothing. A brand Pocket cannot be
  # mounted — `Pockets.Operator` refuses a role-bound Pocket — so `dir` is always
  # the local directory here.
  defp images(slot) do
    case Pockets.load(slot.pocket) do
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

  defp image?(name) do
    name |> Path.extname() |> String.downcase() |> Kernel.in(@image_exts)
  end

  defp custom_url(slot, filename) do
    case Pockets.load(slot.pocket) do
      {:ok, pocket} -> Pockets.asset_url(pocket, filename) || slot.default
      _ -> slot.default
    end
  end
end
