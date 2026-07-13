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
    * `memory/trusted-phone-numbers.md` → `BusterClaw.TrustedNumbers`, read by
      `BusterClaw.Telephony.Drain`

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
  alias BusterClaw.Telephony.Event
  alias BusterClaw.{TrustedNumbers, TrustedSenders}

  @topic "contacts"

  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc "All contacts, name-sorted."
  def list_contacts do
    Repo.all(from c in Contact, order_by: [asc: c.name])
  end

  def get_contact!(id), do: Repo.get!(Contact, id)

  def change_contact(%Contact{} = contact, attrs \\ %{}), do: Contact.changeset(contact, attrs)

  def create_contact(attrs) do
    %Contact{}
    |> Contact.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast()
  end

  def update_contact(%Contact{} = contact, attrs) do
    contact
    |> Contact.changeset(attrs)
    |> Repo.update()
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

  @doc "Phone → contact, for naming rows in the Message Machine log."
  def by_phone do
    list_contacts()
    |> Enum.reject(&is_nil(&1.phone))
    |> Map.new(&{&1.phone, &1})
  end

  ## Trust — derived from the policy files, never from a column.

  @doc """
  Whether this contact may drive follow-through work.

  True when *either* identifier is trusted: a person who is a trusted email
  sender is the same person when they call. Note `TrustedSenders` also honours
  domain wildcards, so an `*@example.com` entry makes every colleague trusted
  without anyone listing them individually — asking the policy (rather than
  storing a bool) is what lets that keep working.
  """
  def trusted?(%Contact{} = contact) do
    phone_trusted?(contact) or email_trusted?(contact)
  end

  def phone_trusted?(%Contact{phone: nil}), do: false
  def phone_trusted?(%Contact{phone: phone}), do: TrustedNumbers.trusted?(phone)

  def email_trusted?(%Contact{email: nil}), do: false
  def email_trusted?(%Contact{email: email}), do: TrustedSenders.trusted?(email)

  @doc """
  Grant or revoke trust for every identifier this contact has.

  Writes straight through to the markdown policy files — this is the same code
  path as the `phone_trusted_add` command and the homepage panel, so there is
  exactly one way to become trusted.

  Returns `{:ok, contact}`, or `{:error, reason}` if a policy write failed. A
  contact with a phone *and* an email touches both files; a partial failure
  (first write succeeded, second did not) reports the error rather than claiming
  success — re-running is safe, since both policies are idempotent.
  """
  def set_trusted(%Contact{} = contact, trusted?) when is_boolean(trusted?) do
    results =
      [
        contact.phone && apply_number_trust(contact.phone, trusted?),
        contact.email && apply_sender_trust(contact.email, trusted?)
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        broadcast(:contacts_changed)
        {:ok, contact}

      {:error, reason} ->
        broadcast(:contacts_changed)
        {:error, reason}
    end
  end

  defp apply_number_trust(phone, true), do: TrustedNumbers.add_entry(phone)

  defp apply_number_trust(phone, false) do
    case TrustedNumbers.remove_entry(phone) do
      :ok -> :ok
      other -> other
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

  Returns `%{emails: [%{type:, value:}], numbers: ["+1..."]}` — note the two
  policies report different shapes: `TrustedSenders` yields tagged maps (it has
  domain wildcards to distinguish), `TrustedNumbers` yields plain E.164 strings
  (it deliberately has no wildcards).

  These are live gate entries — a domain wildcard, or an address the agent added
  over the CLI — so the UI must show them. Hiding them would make the panel claim
  a smaller trust surface than the gate actually has. A `*@domain` rule is *always*
  an orphan: it grants trust to people who have no contact row at all, which is
  exactly why it must stay visible.
  """
  def orphan_entries do
    contacts = list_contacts()
    known_emails = contacts |> Enum.map(& &1.email) |> Enum.reject(&is_nil/1) |> MapSet.new()
    known_phones = contacts |> Enum.map(& &1.phone) |> Enum.reject(&is_nil/1) |> MapSet.new()

    %{
      emails:
        Enum.reject(
          TrustedSenders.list_entries(),
          &(&1.type == :address and MapSet.member?(known_emails, &1.value))
        ),
      numbers: Enum.reject(TrustedNumbers.list_entries(), &MapSet.member?(known_phones, &1))
    }
  end

  ## History

  @doc """
  This contact's call/voicemail/SMS history, newest first.

  Empty for an email-only contact — there is no phone to match on. Email history
  is not folded in here yet; that arrives with the unified timeline.
  """
  def history(%Contact{phone: nil}, _limit), do: []

  def history(%Contact{phone: phone}, limit) when is_integer(limit) do
    Repo.all(
      from e in Event,
        where: e.from_number == ^phone or e.to_number == ^phone,
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: ^limit
    )
  end

  def history(%Contact{} = contact), do: history(contact, 50)

  defp tap_broadcast({:ok, _} = result) do
    broadcast(:contacts_changed)
    result
  end

  defp tap_broadcast(result), do: result

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, message)
    # The Message Machine log names rows from the contact list, so it has to
    # re-render too — it listens on the telephony topic, not this one.
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, "telephony", :telephony_contacts_changed)
  end
end
