defmodule BusterClawWeb.Phone.Shared do
  @moduledoc """
  What the Message Machine's three panels have in common: the shader backdrop,
  the voicemail cost breakdown, and the formatting an event log needs to read
  like a phone rather than a database — labels, icons, phone numbers, durations,
  costs and local times.

  Imported by `Phone.Log`, `Phone.Playback` and `Phone.ContactList` rather than
  aliased, so a panel still writes `format_phone(number)` and `<.shader_bg …>`
  exactly as it did when all three lived in one file. `PhoneComponent` imports
  `format_phone/1` alone, to print the operator's own number in the tab header.

  These are public only because they cross a module boundary now. Nothing
  outside the Phone surface should call them.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Pockets.Faces
  alias BusterClaw.Telephony.Event

  def shader_bg(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="SmokeBackground"
      phx-update="ignore"
      data-shader={@shader}
      data-custom="true"
      data-colors={@colors}
      class="ic-shader-fill"
      aria-hidden="true"
    >
      <canvas data-smoke-canvas></canvas>
    </div>
    """
  end

  # Where the money went, from the back-filled `metadata["cost_breakdown"]`. Shown
  # small under the total — the point of the whole feature (on a voicemail,
  # transcription is usually the driver; on a call, the surprise is that there are
  # two legs at all).
  #
  # One ordered list rather than a branch on `kind`, because a row only ever
  # carries one family's keys and an unknown key should render as nothing rather
  # than as an error. Adding a priced thing means adding a pair here.
  @cost_parts [
    {"call", "call"},
    {"recording", "rec"},
    {"transcription", "txt"},
    {"your_leg", "you"},
    {"their_leg", "them"}
  ]

  attr :event, :map, required: true

  def cost_breakdown(assigns) do
    parts =
      case assigns.event.metadata do
        %{"cost_breakdown" => %{} = breakdown} ->
          for {key, label} <- @cost_parts, is_integer(breakdown[key]), do: {label, breakdown[key]}

        _ ->
          []
      end

    assigns = assign(assigns, parts: parts, incomplete?: incomplete_cost?(assigns.event))

    ~H"""
    <span
      :if={@parts != []}
      class="font-mono text-[10px] text-base-content/45"
    >
      ({Enum.map_join(@parts, " + ", fn {label, micros} -> "#{label} #{format_cost(micros)}" end)}<span :if={
        @incomplete?
      }>, incomplete</span>)
    </span>
    """
  end

  # A row the back-fill gave up on. Saying so is the difference between a number
  # that is final and one that merely stopped changing.
  defp incomplete_cost?(%{metadata: %{"cost_incomplete" => true}}), do: true
  defp incomplete_cost?(_event), do: false

  @doc """
  Whether this row is one the cost back-fill prices — see `Telephony.unpriced_events/1`.

  Kept beside the renderer so the panel that shows a Cost line and the query that
  fills it in cannot disagree about which rows have one.

  **Voicemail only, since 08-18.** This clause used to include
  `%{kind: "call", direction: "outbound"}`, matching the query. Outbound calling
  was deleted (`PHONE_INTAKE_ROADMAP`) and `unpriced_events/1` narrowed to
  voicemail with it, because the pricing path those rows needed is gone and they
  can never be priced again. The rows themselves stay — they are a true record of
  calls that happened — but a Cost line on one would advertise a number that is
  never coming, so the affordance goes and the row does not.
  """
  def priced_kind?(%{kind: "voicemail"}), do: true
  def priced_kind?(_event), do: false

  # --- pure display helpers ------------------------------------------------
  #
  # Formatting only: every one takes values and returns values, touching no
  # socket, no assigns and no context. That is what made them safe to move.

  def unheard?(%Event{kind: "voicemail", heard_at: nil}), do: true
  def unheard?(_event), do: false

  # Keyed on heard-state so marking a voicemail heard remounts the AudioClip
  # hook (phx-update="ignore" otherwise pins the mount-time waveform color).
  def clip_id(%Event{} = event) do
    if unheard?(event), do: "clip-#{event.id}-hot", else: "clip-#{event.id}"
  end

  # Keyed on the chosen face so switching Generative ↔ custom remounts the
  # ShaderFace hook (phx-update="ignore" pins whatever compiled at mount).
  def face_id(contact), do: "face-#{contact.id}-#{contact.face_shader || "gen"}"

  # Where the ShaderFace hook fetches a custom face's WGSL. `Pockets.Faces` owns
  # the order (its Pocket, then `<workspace>/shaders/`) and returns nil for a
  # face that is no longer anywhere — which is the generative face, the same
  # answer as never having picked one.
  def face_source(%{face_shader: nil}), do: nil
  def face_source(%{face_shader: name}), do: Faces.source_url(name)

  # A known contact shows by name everywhere; strangers stay as numbers.
  def display_name(contacts, number) do
    case contacts[number] do
      %{name: name} -> name
      _ -> format_phone(number)
    end
  end

  def kind_icon(%Event{kind: "voicemail"}), do: "hero-phone-arrow-down-left"
  def kind_icon(%Event{kind: "sms", direction: "outbound"}), do: "hero-chat-bubble-left"
  def kind_icon(%Event{kind: "sms"}), do: "hero-chat-bubble-left-ellipsis"
  def kind_icon(%Event{}), do: "hero-phone"

  def event_label(%Event{kind: "voicemail"}), do: "Voicemail"
  def event_label(%Event{kind: "sms", direction: "outbound"}), do: "Text · Sent"
  def event_label(%Event{kind: "sms"}), do: "Text"
  def event_label(%Event{direction: "outbound"}), do: "Call · Out"
  def event_label(%Event{}), do: "Call"

  def preview(%Event{kind: "voicemail", transcript: transcript}) when is_binary(transcript),
    do: transcript

  def preview(%Event{kind: "voicemail"}), do: "(no transcript yet)"
  def preview(%Event{kind: "sms", body: body}), do: body
  def preview(_event), do: nil

  # NANP pretty-print; anything else (short codes, international) stays raw.
  def format_phone("+1" <> <<a::binary-size(3), b::binary-size(3), c::binary-size(4)>>),
    do: "(#{a}) #{b}-#{c}"

  def format_phone(number), do: number

  def format_duration(seconds) when is_integer(seconds) do
    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  # Micro-USD → a dollar string, up to 4 decimals with trailing zeros trimmed but
  # at least cents (2 places). So a 24¢ total reads "$0.24" while a sub-cent
  # component like the call leg still reads "$0.0085" instead of rounding to
  # "$0.01". `nil` (not priced yet) → nil; the caller renders "pricing…".
  def format_cost(micros) when is_integer(micros) do
    "$" <> ((micros / 1_000_000) |> :erlang.float_to_binary(decimals: 4) |> trim_cost_zeros())
  end

  def format_cost(_nil), do: nil

  defp trim_cost_zeros(str) do
    [whole, frac] = String.split(str, ".")
    frac = String.trim_trailing(frac, "0") |> String.pad_trailing(2, "0")
    "#{whole}.#{frac}"
  end

  def format_dt(%DateTime{} = dt), do: Elixir.Calendar.strftime(to_local(dt), "%b %d %H:%M")
  def format_dt(_), do: ""

  def format_dt_full(%DateTime{} = dt),
    do: Elixir.Calendar.strftime(to_local(dt), "%A, %B %d %Y · %H:%M")

  def format_dt_full(_), do: ""

  # OS-local wall time via Erlang's tz handling — the app carries no tzdata dep,
  # and a phone log in UTC misreads ("who called me at 03:00?").
  def to_local(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end
end
