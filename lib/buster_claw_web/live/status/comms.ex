defmodule BusterClawWeb.Status.Comms do
  @moduledoc """
  The corner widget's Contacts tab: the trust gate, and the recent-phone-activity
  feed, shaped for display.

  `HomeWidget` is presentational, so the rows it renders are built here — a
  counterparty name (or bare number), a direction mark, a human title, a
  one-line snippet, and a coarse relative timestamp.

  Trust is re-read from the policy files on every load rather than cached in the
  socket, because this tab is not the only writer: the `/phone` view, the
  `phone_trusted_*` commands, and the agent editing the markdown directly all
  move the same gate.
  """
  import Phoenix.Component

  alias BusterClaw.Contacts
  alias BusterClaw.Telephony

  # The gate, split into the part with a person behind it and the part without.
  # Both halves are rendered — see `TrustedContactsPanel` for why omitting the
  # orphans would understate the trust surface.
  #
  # Trust is read from the policy files on every load rather than cached in the
  # socket, because this tab is not the only writer: the `/phone` view, the
  # `phone_trusted_*` commands, and the agent editing the markdown directly all
  # move the same gate.
  def load_trust(socket) do
    people = Enum.filter(Contacts.list_contacts(), &Contacts.email_trusted?/1)

    socket
    |> assign(:trusted_people, people)
    |> assign(:trusted_entries, Contacts.orphan_entries().emails)
  end

  # The corner-widget "Contacts" tab is a comms hub: recent phone activity plus
  # the contact list (with a trusted marker) and per-person actions. Both are
  # pre-shaped here so HomeWidget stays presentational.
  def load_comms(socket) do
    contacts = Contacts.list_contacts()
    names = Contacts.by_phone(contacts)

    people =
      Enum.map(contacts, fn c ->
        %{id: c.id, name: c.name, phone: c.phone, email: c.email, trusted?: Contacts.trusted?(c)}
      end)

    activity = Enum.map(Telephony.list_events(limit: 6), &activity_row(&1, names))

    socket
    |> assign(:comms_contacts, people)
    |> assign(:phone_activity, activity)
  end

  # Shape one telephony event into a compact widget row: the other party's name
  # (or bare number), a direction mark + human title, a one-line snippet, and a
  # relative timestamp.
  defp activity_row(event, names) do
    number = Telephony.counterparty(event)

    label =
      case Map.get(names, number) do
        %{name: name} -> name
        _ -> number || "Unknown"
      end

    %{
      id: event.id,
      label: label,
      mark: if(event.direction == "outbound", do: "↗", else: "↙"),
      title: "#{String.capitalize(event.direction)} #{kind_label(event.kind)}",
      snippet: activity_snippet(event),
      when: relative_time(event.occurred_at)
    }
  end

  def kind_label("voicemail"), do: "voicemail"
  def kind_label("sms"), do: "text"
  def kind_label("call"), do: "call"
  def kind_label(other), do: other

  defp activity_snippet(%{kind: "sms", body: body}) when is_binary(body), do: snip(body)

  defp activity_snippet(%{kind: "voicemail", transcript: t}) when is_binary(t) and t != "",
    do: snip(t)

  defp activity_snippet(%{kind: "voicemail"}), do: "voicemail"
  defp activity_snippet(%{kind: "call"}), do: "call"
  defp activity_snippet(_), do: ""

  def snip(text) do
    text = String.trim(text)
    if String.length(text) > 60, do: String.slice(text, 0, 60) <> "…", else: text
  end

  # A coarse relative timestamp for the activity feed ("3m", "2h", "5d"); older
  # than a week falls back to a short date. occurred_at is UTC; so is now/0.
  defp relative_time(nil), do: ""

  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(now(), dt, :second)

    cond do
      seconds < 60 -> "now"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d"
      true -> Elixir.Calendar.strftime(dt, "%b %-d")
    end
  end

  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
