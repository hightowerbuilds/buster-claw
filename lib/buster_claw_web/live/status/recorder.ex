defmodule BusterClawWeb.Status.Recorder do
  @moduledoc """
  Recording state for the **Voice Library** — the in-app recorder
  (`STUDIO_ROADMAP` V.6–V.8) and the voice banks it records into (V.0).

  A sibling of `Status.Voice` rather than part of it. They back one tab and are
  two modules on purpose: this one owns a microphone, a device list and a bank
  roster; that one owns a corpus report and a phrase. Nothing is shared but the
  bank they both read, and merging them would produce a ~400-line module whose
  halves never call each other.

  ## One assign, not eight

  Everything here lives under a single `:contribute` map. That is a departure
  from `Status.Voice`, which assigns six independent scalars, and it is
  deliberate on two grounds: this state is genuinely one cohesive thing (a
  bank, a device, a word, a pending take), and `status_live.ex` sits at 959 lines
  against a 970 cap that exists because a 1,460-line LiveView was decomposed
  once and must not grow back. Eight `attr`s threaded through the panel would
  have spent that headroom on punctuation.

  ## The capability gate is the client's answer, not a guess here

  **Nothing in this app has ever opened a microphone**, and whether it can is an
  unresolved question — V.4a, the `getUserMedia` spike, has never been run
  against a packaged build. So the server does not claim to know. It starts at
  `:unproven` and the browser reports what it actually found:

  | State | Means |
  |---|---|
  | `:unproven` | the hook has not answered yet |
  | `:ready` | a real input stream opened |
  | `:denied` | the host refused — with the reason it gave |
  | `:unsupported` | no `mediaDevices` at all |

  This is why the recorder can be built and shipped before the entitlement is:
  in Chrome at `localhost:4000` and in `cargo tauri dev` it may genuinely work
  today, and in a packaged build it will honestly say what stopped it instead of
  offering a button that does nothing. The alternative — hard-coding "capture is
  unavailable" — would have made the feature untestable by the one person who
  can run the spike.
  """
  import Phoenix.Component

  alias BusterClaw.Notifications.Capture.Devices
  alias BusterClaw.Notifications.Capture.Take
  alias BusterClaw.Notifications.Cutup.Bank
  alias BusterClawWeb.Status.Voice

  @doc "Mount defaults. Reads the bank roster; touches no hardware and no audio."
  def assign_recorder(socket) do
    assign(socket, :recorder, %{
      banks: Bank.list(),
      bank: Bank.active(),
      devices: [],
      device: nil,
      word: "",
      capture: :unproven,
      capture_detail: nil,
      notice: nil
    })
  end

  @doc """
  Load what the tab needs when it is opened. Idempotent.

  Device enumeration is a `system_profiler` call, so it waits for the tab rather
  than running at mount — the same laziness `Status.Voice` applies to the corpus.
  """
  def ensure_loaded(%{assigns: %{recorder: %{devices: [_ | _]}}} = socket), do: socket
  def ensure_loaded(socket), do: load_devices(socket)

  @doc """
  Dispatch a `contribute` event.

  One entry point rather than six `handle_event/3` clauses in `StatusLive` — see
  the moduledoc on why that file has no room to spare. An unrecognised action
  returns the socket untouched, so a stale client cannot crash the tab.
  """
  def handle("bank_select", %{"name" => name}, socket) do
    case Bank.set_active(name) do
      {:ok, active} ->
        socket
        |> put(:bank, active)
        |> put(:notice, nil)
        |> Voice.clear_selection()
        |> reload_corpus()

      {:error, reason} ->
        put(socket, :notice, {:error, "That bank could not be selected: #{reason}."})
    end
  end

  def handle("bank_create", %{"name" => name} = params, socket) do
    case Bank.create(name, Map.get(params, "label")) do
      {:ok, bank} ->
        socket
        |> put(:banks, Bank.list())
        |> put(:notice, {:ok, "Created #{bank.label}. Select it to record into it."})

      {:error, reason} ->
        put(socket, :notice, {:error, create_error(reason)})
    end
  end

  def handle("word", %{"word" => word}, socket), do: put(socket, :word, word)

  def handle("device", %{"device" => device}, socket), do: put(socket, :device, device)

  def handle("capability", params, socket) do
    socket
    |> put(:capture, capability(Map.get(params, "state")))
    |> put(:capture_detail, detail(Map.get(params, "detail")))
  end

  def handle("refresh", _params, socket) do
    socket |> load_devices() |> reload_corpus()
  end

  def handle(_action, _params, socket), do: socket

  @doc """
  Prefill the text the operator is about to say.

  Public because the Sentence pane's **missing** chips lead here: a word with no
  take is the one verdict a recording can change, so clicking it arms the
  recorder for exactly that word. That is the arrow back in the Library's own
  loop — you find a gap by building a sentence, and you close it by recording.
  """
  def put_word(socket, word) when is_binary(word), do: put(socket, :word, word)
  def put_word(socket, _word), do: socket

  @doc """
  Store a take the recorder captured, and refresh the corpus so the new word
  appears in Voice immediately.

  ## It calls `Capture.Take` directly, and must never call the command surface

  The obvious implementation was `Commands.call("sound_record_save", …)` — the
  same verb an agent uses, one code path, apparently tidier. It is forbidden, and
  `remote_mode_test.exs` fails the build if it reappears:

  > `Commands.call/3` defaults to `caller: :trusted`. A LiveView carries no API
  > token, so a call from one would run as FULLY TRUSTED — and a remote browser
  > driving that LiveView would inherit it, bypassing the tier system entirely.

  That is not hypothetical for this feature: `sound_record_save` is **gated**,
  the tier reserved for outbound and irreversible actions. A UI path into it
  would be a hole in exactly the place the Clinch's remote mode is being built to
  defend.

  So the domain module is the shared thing, not the command. Both callers get the
  same refusals because `Take.store/3` owns them — see its `refuse_clipped/1`.
  """
  def save_take(socket, params) do
    with {:ok, take} <- Take.decode(Map.get(params, "pcm"), Map.get(params, "sample_rate")),
         {:ok, source} <- Take.store(take, nil, socket.assigns.recorder.word) do
      socket
      |> put(:notice, {:ok, saved_message(source, socket.assigns.recorder.word, take.peak)})
      |> put(:word, "")
      |> reload_corpus()
    else
      {:error, reason} -> put(socket, :notice, {:error, save_error(reason)})
    end
  end

  @doc "Whether the record control may be armed at all."
  def recordable?(%{capture: :ready, word: word}) when is_binary(word),
    do: String.trim(word) != ""

  def recordable?(_contribute), do: false

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp load_devices(socket) do
    case Devices.list() do
      {:ok, devices} -> socket |> put(:devices, devices) |> put(:device, default_device(devices))
      {:error, _reason} -> put(socket, :devices, [])
    end
  end

  # The system default is the honest starting selection, but V.0's rule is that a
  # donor session PINS a device — macOS can move the default out from under a
  # long take. So this seeds the picker and the operator's choice sticks.
  defp default_device(devices) do
    case Enum.find(devices, & &1.default?) || List.first(devices) do
      nil -> nil
      device -> device.name
    end
  end

  # The Voice tab reads the ACTIVE bank, so switching banks or adding a word has
  # to invalidate its cached report or the dictionary silently describes the
  # bank the operator just left.
  defp reload_corpus(socket), do: Voice.load_report(socket)

  defp put(socket, key, value),
    do: assign(socket, :recorder, Map.put(socket.assigns.recorder, key, value))

  defp capability(state) when state in ["ready", "denied", "unsupported"],
    do: String.to_existing_atom(state)

  defp capability(_state), do: :unproven

  defp detail(detail) when is_binary(detail), do: String.slice(detail, 0, 200)
  defp detail(_detail), do: nil

  defp saved_message(source, word, peak) do
    "Saved #{source} as a take of “#{String.trim(word)}” · peak #{peak_db(peak)}."
  end

  # dBFS rather than a fraction, because that is the scale the meter uses and the
  # scale V.6 sets the target zone on. Silence would be negative infinity; the
  # take was refused long before here if it were silent.
  defp peak_db(peak) when is_number(peak) and peak > 0 do
    "#{Float.round(20 * :math.log10(peak), 1)} dBFS"
  end

  defp peak_db(_peak), do: "unknown"

  # Both error tables are MAPS with a default rather than a clause per atom, and
  # the reason is a Dialyzer property worth keeping: a clause-per-atom set covers
  # everything the callee can actually return, which makes the catch-all
  # unreachable — `pattern_match_cov`, exactly the finding that turned the gate
  # red on 08-16 in `commands/appearance.ex`.
  #
  # Deleting the catch-all would go green and make the function PARTIAL: a new
  # error atom would then raise `FunctionClauseError` in front of the operator,
  # and neither Dialyzer nor the suite catches that (measured — see the comment
  # at that deletion site). A map lookup is total AND has no pattern to prove
  # unreachable, so it is the version that is both green and safe.
  @create_errors %{
    invalid_name: "A bank name is lowercase letters, numbers and hyphens, up to 32 characters.",
    already_exists: "That bank already exists.",
    reserved_name: "That name is reserved."
  }

  defp create_error(reason) do
    Map.get(@create_errors, reason, "That bank could not be created: #{inspect(reason)}.")
  end

  # Same shape as @create_errors above, for the same reason.
  @save_errors %{
    clipped_take:
      "That take clipped, so it was not saved — the waveform is already flat at the top " <>
        "and no amount of gain repairs it. Lower the input level and record it again.",
    silent_take:
      "That take was silent. The device is muted, or the app was never granted the microphone.",
    name_taken: "There is already a source with that name, and a recording is never overwritten.",
    name_required: "That word has no letters or numbers to name a file with.",
    invalid_pcm: "The recording did not arrive intact. Try that take again.",
    invalid_sample_rate: "The input reported a sample rate this app cannot use.",
    empty_take: "Nothing was captured — the take was too short."
  }

  defp save_error(reason) do
    Map.get(@save_errors, reason, "The take could not be saved: #{inspect(reason)}.")
  end
end
