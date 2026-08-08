defmodule BusterClawWeb.Phone.Shared do
  @moduledoc """
  What the Message Machine's three panels have in common: the shader backdrop,
  the voicemail cost breakdown, and the formatting an event log needs to read
  like a phone rather than a database — labels, icons, phone numbers, durations,
  costs and local times.

  Imported by `Phone.Log`, `Phone.Playback` and `Phone.ContactList` rather than
  aliased, so a panel still writes `format_phone(number)` and `<.shader_bg …>`
  exactly as it did when all three lived in one file.

  These are public only because they cross a module boundary now. Nothing
  outside `BusterClawWeb.Phone` should call them.
  """
  use BusterClawWeb, :html

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

  # The three components of a voicemail's cost (call leg / recording /
  # transcription), from the back-filled `metadata["cost_breakdown"]`. Shown small
  # under the total so the operator can see *where* the money goes — the point of
  # the whole feature (transcription is usually the driver).
  attr :event, :map, required: true

  def cost_breakdown(assigns) do
    parts =
      case assigns.event.metadata do
        %{"cost_breakdown" => %{} = b} ->
          [{"call", b["call"]}, {"rec", b["recording"]}, {"txt", b["transcription"]}]
          |> Enum.filter(fn {_label, micros} -> is_integer(micros) end)

        _ ->
          []
      end

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span
      :if={@parts != []}
      class="font-mono text-[10px] text-base-content/45"
    >
      ({Enum.map_join(@parts, " + ", fn {label, micros} -> "#{label} #{format_cost(micros)}" end)})
    </span>
    """
  end

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

  def face_source(%{face_shader: nil}), do: nil
  def face_source(%{face_shader: name}), do: ~p"/shaders/#{name}"

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

  def format_dialed(<<a::binary-size(3), b::binary-size(3), c::binary-size(4)>>),
    do: "(#{a}) #{b}-#{c}"

  def format_dialed(number), do: number

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

  def trim_cost_zeros(str) do
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
