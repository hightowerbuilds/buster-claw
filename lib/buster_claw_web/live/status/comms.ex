defmodule BusterClawWeb.Status.Comms do
  @moduledoc """
  The corner widget's Contacts tab, shaped for display: the trust gate and the
  people list. `HomeWidget` is presentational, so the rows are built here.

  Trust is re-read from the policy file on every load rather than cached in the
  socket, because this tab is not the only writer: the agent editing the
  markdown directly moves the same gate.
  """
  import Phoenix.Component

  alias BusterClaw.Contacts

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
end
