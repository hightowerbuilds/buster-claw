defmodule BusterClawWeb.Status.Comms do
  @moduledoc """
  The Clock panel's Contacts tab: the trust gate and the people list, shaped
  for display, and the three verbs that move the gate (add-and-trust, drop an
  orphan entry, untrust a contact). `HomeWidget` is presentational, so the rows
  are built here; `StatusLive` keeps the `handle_event` clauses and delegates
  one line deep, the `Status.Chat` shape.

  Trust is re-read from the policy file on every load rather than cached in the
  socket, because this tab is not the only writer: the agent editing the
  markdown directly moves the same gate.
  """
  import Phoenix.Component
  import Phoenix.LiveView, only: [put_flash: 3]

  alias BusterClaw.Contacts
  alias BusterClaw.TrustedSenders

  # The gate, split into the part with a person behind it and the part without.
  # Both halves are rendered — see `TrustedContactsPanel` for why omitting the
  # orphans would understate the trust surface.
  def load_trust(socket) do
    people = Enum.filter(Contacts.list_contacts(), &Contacts.email_trusted?/1)

    socket
    |> assign(:trusted_people, people)
    |> assign(:trusted_entries, Contacts.orphan_entries().emails)
  end

  # Every contact, with a trusted marker, for the people column.
  def load_contacts(socket) do
    people =
      Enum.map(Contacts.list_contacts(), fn c ->
        %{id: c.id, name: c.name, email: c.email, trusted?: Contacts.trusted?(c)}
      end)

    assign(socket, :comms_contacts, people)
  end

  # A name and an email, created and trusted in one step — the only reason an
  # operator adds someone is so their mail becomes work.
  def add_trusted_contact(socket, params) do
    with {:ok, contact} <- Contacts.create_contact(Map.take(params, ["name", "email"])),
         {:ok, _} <- Contacts.set_trusted(contact, true) do
      socket
      |> assign(adding_contact: false, contact_error: nil)
      |> load_trust()
      |> load_contacts()
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, :contact_error, first_contact_error(changeset))

      {:error, reason} ->
        assign(socket, :contact_error, "could not update trust: #{inspect(reason)}")
    end
  end

  # Removing an *orphan* entry — an address or wildcard with no contact behind it.
  # There is nothing else to clean up, so the policy line is simply dropped.
  def remove_trust_entry(socket, entry) do
    TrustedSenders.remove_entry(entry)
    load_trust(socket)
  end

  # Untrusting a *contact* is not the same act as deleting them. This revokes the
  # policy entry and leaves the person in your contacts — their mail stops being
  # queued, their name stays. Conflating the two would let a UI tidy-up quietly
  # rewrite the security policy.
  def untrust_contact(socket, id) do
    contact = Contacts.get_contact!(id)

    case Contacts.set_trusted(contact, false) do
      {:ok, _} ->
        load_trust(socket)

      {:error, reason} ->
        socket
        |> put_flash(:error, "Could not update the trust policy: #{inspect(reason)}")
        |> load_trust()
    end
  end

  defp first_contact_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field} #{&1}") end)
    |> List.first()
    |> Kernel.||("could not save the contact")
  end
end
