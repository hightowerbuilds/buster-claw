defmodule BusterClaw.Notifications.Cutup.Bank do
  @moduledoc """
  Voice banks — the partition `STUDIO_ROADMAP` V.0 requires before anyone can
  contribute audio (Part V, the contribution half).

  ## Why this exists, in one rule

  V.0 reached the same conclusion three independent ways — engineering,
  measurement, and law — and stated it once:

  > **Banks never merge, and a bank is a voice-and-channel, not a folder.**

  A cut-up splices fragments of *different recordings of the same word* into one
  phrase. Do that within one voice and one microphone and the result sounds
  intentional. Do it across two voices and it sounds broken — not subtly, and
  not fixably downstream, because `Cutup.Dtw` matches on timbre and will happily
  rank a stranger's take as the best fit. `sound_find` is *"speaker- and
  channel-dependent by design"*, and Part IV's lattice was built for one speaker.

  So a corpus that accepts contributions from more than one person needs a
  partition, and this module is it.

  ## A bank is metadata, deliberately not a directory

  The rule says a bank is *not a folder*, and this module takes that literally:
  a bank is a **field on the index**, and `sounds/studio/` stays flat.

  That is not a shortcut. Three things fall out of it that a directory layout
  would have cost:

  - **Every existing index stays readable.** `Cutup.Index`'s filename carries the
    source basename and nothing else; moving files would orphan all ten of the
    corpus's indexes and every path in them.
  - **A source can be re-attributed without moving audio.** Discovering that a
    recording is a different speaker is a one-field edit, not a file move that
    invalidates `Cutup.Features`' cache keys.
  - **The audio is untouched by the concept.** `SoundStudio.list/0` reports the
    studio's sources, and a bank is a claim about *whose voice is in one*, which
    is not a fact about where the bytes live.

  ## The default bank, and why it is named

  An index written before this module existed carries no bank. It reads as
  `default/0` — `"voicemail"` — rather than as `nil` or
  `"unknown"`, because the ten sources in that corpus **are** one voice-and-channel
  (one caller, one phone line) and V.1 says so explicitly: *"Keep the voicemail
  corpus as its own separate voice. Don't merge banks."* Naming it at the point of
  backfill is the difference between a partition and a pile.

  `default/0` is reserved: it cannot be deleted, and `create/2` refuses it.

  ## What this module does NOT decide

  It holds the roster and the pointer, and nothing else. It does not read audio,
  does not count takes, and does not know what an index looks like — `Cutup.Gaps`
  answers "how big is this bank?" because that is a measurement over indexes, and
  putting it here would make a registry depend on the corpus it partitions.
  """

  alias BusterClaw.Settings

  @roster_key "studio.voice.banks"
  @active_key "studio.voice.active_bank"

  # The bank every pre-08-16 index belongs to. See the moduledoc: this is the
  # voicemail corpus, which is one voice and one channel and therefore already a
  # bank — it simply predates the word.
  @default "voicemail"
  @default_label "Voicemail"

  # Same shape as a source name, and for the same reason: a bank name reaches a
  # JSON field that is hand-editable by design, so it must survive a round trip
  # through a text editor without acquiring a path separator. Deliberately
  # stricter than `Cutup.SourceName` — no dots, because a bank has no extension
  # and `voicemail.old` reads as a filename that is not one.
  @name_pattern ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/

  @typedoc "A bank: a stable name, and a label the operator reads."
  @type t :: %{name: String.t(), label: String.t()}

  @typedoc "Why a call was refused. Returned, never raised."
  @type error :: :invalid_name | :reserved_name | :already_exists | :not_found | :bank_in_use

  @doc "The bank an index with no bank of its own belongs to."
  @spec default() :: String.t()
  def default, do: @default

  @doc """
  Every bank, default first, then the rest alphabetically by name.

  The default is always present even if the roster setting is missing or
  corrupt — a corpus cannot have no banks, and answering `[]` would make the
  Voice tab render a selector with nothing in it.
  """
  @spec list() :: [t()]
  def list do
    [%{name: @default, label: @default_label} | roster()]
    |> Enum.uniq_by(& &1.name)
    |> then(fn [head | tail] -> [head | Enum.sort_by(tail, & &1.name)] end)
  end

  @doc "Whether a bank exists."
  @spec known?(term()) :: boolean()
  def known?(name) when is_binary(name), do: Enum.any?(list(), &(&1.name == name))
  def known?(_name), do: false

  @doc """
  The bank new recordings are attributed to, and the one the dictionary reads.

  Falls back to `default/0` when unset **or when the stored value names a bank
  that no longer exists** — a dangling pointer would otherwise make the Voice tab
  report an empty corpus and read as data loss rather than a deleted bank.
  """
  @spec active() :: String.t()
  def active do
    case Settings.get(@active_key) do
      name when is_binary(name) -> if known?(name), do: name, else: @default
      _other -> @default
    end
  end

  @doc "Point the dictionary and the recorder at a bank. Refuses an unknown one."
  @spec set_active(term()) :: {:ok, String.t()} | {:error, error()}
  def set_active(name) when is_binary(name) do
    if known?(name) do
      Settings.put(@active_key, name)
      {:ok, name}
    else
      {:error, :not_found}
    end
  end

  def set_active(_name), do: {:error, :invalid_name}

  @doc """
  Add a bank. `label` is what the operator reads; it defaults to the name.

  Creating a bank is deliberately cheap and reversible — it writes no file and
  touches no audio. A bank with no takes in it is a valid, useful thing: it is
  what "I am about to record someone new" looks like before the first take.
  """
  @spec create(term(), term()) :: {:ok, t()} | {:error, error()}
  def create(name, label \\ nil)

  def create(name, label) when is_binary(name) do
    with {:ok, safe} <- safe_name(name),
         :ok <- refuse_existing(safe) do
      bank = %{name: safe, label: label(label, safe)}
      write_roster([bank | roster()])
      {:ok, bank}
    end
  end

  def create(_name, _label), do: {:error, :invalid_name}

  @doc """
  Remove a bank from the roster.

  **Refuses a bank that any index still names** (`:bank_in_use`), because the
  alternative is takes that belong to a bank the roster cannot describe — which
  is precisely the "pile" state this module exists to prevent. Re-attribute or
  delete those indexes first. The default bank can never be removed.

  ## Why the caller supplies `in_use?` instead of this module measuring it

  The obvious version read every index here and answered for itself. It created a
  **compile cycle** — `Bank` → `Index` → `Bank` — which `check_cycles.sh` caught,
  and the cycle was the honest signal: this module's own contract says it "does
  not know what an index looks like", and a registry that reads the corpus it
  partitions is exactly the coupling the split exists to avoid.

  So the measurement lives in `Cutup.Gaps.bank_in_use?/1`, which already loads
  indexes, and arrives here as a boolean. Passing it is **not optional** — the
  arity forces the question rather than letting a caller forget it and silently
  orphan takes, which is what a `delete/1` trusting an internal check would have
  allowed the moment someone bypassed it.
  """
  @spec delete(term(), boolean()) :: :ok | {:error, error()}
  def delete(name, in_use?)

  def delete(@default, _in_use?), do: {:error, :reserved_name}

  def delete(name, in_use?) when is_binary(name) and is_boolean(in_use?) do
    cond do
      not known?(name) -> {:error, :not_found}
      in_use? -> {:error, :bank_in_use}
      true -> write_roster(Enum.reject(roster(), &(&1.name == name)))
    end
  end

  def delete(_name, _in_use?), do: {:error, :invalid_name}

  @doc """
  The canonical form of a bank name, or why it is unusable.

  Lowercase, alphanumeric and hyphens, 1–32 characters, starting with an
  alphanumeric. Leading/trailing whitespace is trimmed and inner spaces become
  hyphens, so an operator typing `Aunt Mary` gets `aunt-mary` rather than a
  refusal — but anything that would still not match after that is refused rather
  than silently mangled into a different name.
  """
  @spec safe_name(term()) :: {:ok, String.t()} | {:error, error()}
  def safe_name(name) when is_binary(name) do
    candidate =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/u, "-")

    if Regex.match?(@name_pattern, candidate) do
      {:ok, candidate}
    else
      {:error, :invalid_name}
    end
  end

  def safe_name(_name), do: {:error, :invalid_name}

  @doc """
  The bank an index belongs to, tolerant of every shape an index can arrive in.

  Anything that is not a **well-formed** bank name — absent, `nil`, a number, a
  string with a path separator in it — reads as `default/0`. A take is never
  bankless: that is the invariant the dictionary's "one voice" promise rests on,
  and it is enforced on the way *out* of storage rather than trusted on the way
  in, because the index files are hand-editable by design.

  ## It checks the SHAPE of the name, never the roster, and that is deliberate

  Two reasons, and the first one is not a preference:

  **`Cutup.Index` must stay database-free.** This function is called once per
  index file inside `Index.load/1` and `encode/2`; a roster lookup would put a
  `Settings.get/2` — an Ecto query — in the middle of a pure file-and-JSON
  module, on a path `Cutup.Gaps` walks across the whole corpus on every report.
  It also broke 46 tests the moment it was tried: the `Cutup` suites run without
  a checked-out sandbox connection precisely *because* that layer touches no
  database, and that property is worth more than the check.

  **A deleted bank's takes should keep their attribution.** If the roster were
  consulted, removing a bank would silently re-file every one of its takes into
  the voicemail corpus — merging two voices, which is the one thing this module
  exists to prevent. Keeping the name means the takes stay honestly labelled and
  the bank can simply be re-created. `delete/1` refuses an in-use bank anyway, so
  this is the second lock on the same door rather than the only one.

  Roster membership is checked where a **caller** names a bank — `Index.build/3`,
  `set_active/1`, the Voice tab — because that is where a typo can still be
  refused before it reaches a file.
  """
  @spec of(term()) :: String.t()
  def of(%{bank: name}) when is_binary(name), do: well_formed(name)
  def of(%{"bank" => name}) when is_binary(name), do: well_formed(name)
  def of(_index), do: @default

  defp well_formed(name), do: if(Regex.match?(@name_pattern, name), do: name, else: @default)

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  # The roster is the banks the operator ADDED. `list/0` prepends the default, so
  # the stored value never has to carry it and a cleared setting is still a valid
  # one-bank corpus rather than a broken zero-bank one.
  defp roster do
    case Settings.get(@roster_key) do
      value when is_binary(value) -> decode_roster(value)
      _other -> []
    end
  end

  defp decode_roster(value) do
    case Jason.decode(value) do
      {:ok, entries} when is_list(entries) -> entries |> Enum.flat_map(&entry/1) |> dedupe()
      _other -> []
    end
  end

  # One malformed entry drops itself rather than the whole roster. A corrupt
  # settings row should cost the operator one bank they can re-add, not every
  # bank they have.
  defp entry(%{"name" => name} = map) when is_binary(name) do
    case safe_name(name) do
      {:ok, safe} -> [%{name: safe, label: label(Map.get(map, "label"), safe)}]
      {:error, _reason} -> []
    end
  end

  defp entry(_other), do: []

  defp dedupe(entries), do: Enum.uniq_by(entries, & &1.name)

  defp write_roster(entries) do
    payload =
      entries
      |> dedupe()
      |> Enum.reject(&(&1.name == @default))
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&%{"name" => &1.name, "label" => &1.label})

    case Jason.encode(payload) do
      {:ok, json} ->
        Settings.put(@roster_key, json)
        :ok

      {:error, _reason} ->
        {:error, :invalid_name}
    end
  end

  defp refuse_existing(@default), do: {:error, :reserved_name}

  defp refuse_existing(name) do
    if known?(name), do: {:error, :already_exists}, else: :ok
  end

  # An all-whitespace label falls back to the name rather than to nil: `label` is
  # what the selector renders, and a bank with a blank one reads as a corrupt row.
  defp label(label, name) when is_binary(label) do
    case String.trim(label) do
      "" -> name
      trimmed -> trimmed
    end
  end

  defp label(_label, name), do: name
end
