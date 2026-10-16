defmodule BusterClaw.Contacts do
  @moduledoc """
  One contact list, both channels — the person behind an email address and the
  person behind a phone number are the same person, so they are one row.

  ## Trust is derived, not stored

  This context deliberately owns **no** trust column. The gates that actually
  decide whether an inbound message becomes agent work are the two markdown
  policy files in the workspace:

    * `memory/trusted-email-senders.md` → `BusterClaw.TrustedSenders`, read by
      `BusterClaw.Google.GmailSync`

  (The phone-side twin, `memory/trusted-phone-numbers.md`, left with the phone
  on 10-15. A contact's `phone` column stays as a fact about a person.)

  `trusted?/1` asks those files; `set_trusted/2` writes to them. So the switch in
  the UI *is* the switch in the gate — there is no second copy to drift.

  This matters more than it looks. The predecessor table (`telephony_contacts`)
  carried a `trusted` boolean that nothing read and that defaulted to `true`; a
  UI bound to it would have shown a trust state the gate did not share. Keep it
  derived and that class of bug cannot be written.

  ## Orphans

  The policy files are the source of truth, and they can hold entries no contact
  owns — a domain wildcard (`*@example.com`), or an address the agent added over
  the CLI. Those are **not** deleted or hidden just because no contact row points
  at them; `orphan_entries/0` surfaces them so the UI can show the whole gate,
  not just the part with a name attached.
  """

  import Ecto.Query, warn: false

  alias BusterClaw.Contacts.Contact
  alias BusterClaw.Repo
  alias BusterClaw.TrustedSenders

  @topic "contacts"

  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc "All contacts, name-sorted."
  def list_contacts do
    Repo.all(from c in Contact, order_by: [asc: c.name])
  end

  def get_contact!(id), do: Repo.get!(Contact, id)

  def create_contact(attrs) do
    %Contact{}
    |> Contact.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast()
  end

  @doc """
  Delete a contact.

  Deliberately does **not** revoke trust. Deleting a row that says "+1503… is
  Marcus" should not silently change who may drive the agent's work queue — those
  are different decisions, and conflating them means a UI tidy-up quietly edits
  the security policy. Untrust first (`set_trusted(contact, false)`), then delete,
  if that is what you mean. The entry lives on as an orphan until you do.
  """
  def delete_contact(%Contact{} = contact) do
    contact
    |> Repo.delete()
    |> tap_broadcast()
  end

  ## Trust — derived from the policy files, never from a column.

  @doc """
  Whether this contact may drive follow-through work.

  `TrustedSenders` honours domain wildcards, so an `*@example.com` entry makes
  every colleague trusted without anyone listing them individually — asking the
  policy (rather than storing a bool) is what lets that keep working.
  """
  def trusted?(%Contact{} = contact), do: email_trusted?(contact)

  def email_trusted?(%Contact{email: nil}), do: false
  def email_trusted?(%Contact{email: email}), do: TrustedSenders.trusted?(email)

  @doc """
  Grant or revoke trust for every identifier this contact has.

  Writes straight through to the markdown policy file — the same path the
  homepage panel takes, so there is exactly one way to become trusted. A
  contact with no email has nothing to trust and is left as it is.

  Returns `{:ok, contact}`, or `{:error, reason}` if the policy write failed;
  re-running is safe, since the policy is idempotent.
  """
  def set_trusted(%Contact{} = contact, trusted?) when is_boolean(trusted?) do
    result = contact.email && apply_sender_trust(contact.email, trusted?)
    broadcast(:contacts_changed)

    case result do
      {:error, reason} -> {:error, reason}
      _ -> {:ok, contact}
    end
  end

  defp apply_sender_trust(email, true), do: TrustedSenders.add_entry(email)

  defp apply_sender_trust(email, false) do
    case TrustedSenders.remove_entry(email) do
      :ok -> :ok
      other -> other
    end
  end

  @doc """
  Policy entries that no contact accounts for.

  Returns `%{emails: [%{type:, value:}]}` — `TrustedSenders` yields tagged
  maps, because it has domain wildcards to distinguish.

  These are live gate entries — a domain wildcard, or an address the agent added
  over the CLI — so the UI must show them. Hiding them would make the panel claim
  a smaller trust surface than the gate actually has. A `*@domain` rule is *always*
  an orphan: it grants trust to people who have no contact row at all, which is
  exactly why it must stay visible.

  Accepts an already-loaded contact list so a caller holding one need not
  re-query.
  """
  def orphan_entries(contacts \\ nil) do
    contacts = contacts || list_contacts()
    known_emails = contacts |> Enum.map(& &1.email) |> Enum.reject(&is_nil/1) |> MapSet.new()

    %{
      emails:
        Enum.reject(
          TrustedSenders.list_entries(),
          &(&1.type == :address and MapSet.member?(known_emails, &1.value))
        )
    }
  end

  defp tap_broadcast({:ok, _} = result) do
    broadcast(:contacts_changed)
    result
  end

  defp tap_broadcast(result), do: result

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, message)
  end
end
