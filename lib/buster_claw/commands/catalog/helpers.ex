defmodule BusterClaw.Commands.Catalog.Helpers do
  @moduledoc """
  Shared entry builders for the per-domain catalog modules under
  `BusterClaw.Commands.Catalog.*`.
  """

  @id_required %{"id" => %{type: :integer, required: true}}

  # Google commands all accept an optional account selector — `account_id` or
  # `email` — to choose which connected Workspace account to act as. `google_args/1`
  # merges that shared pair into each command's own args, so the selector is
  # defined once here instead of repeated on every Google entry.
  @google_account %{
    "account_id" => %{type: :integer, required: false},
    "email" => %{type: :string, required: false}
  }

  def id_required, do: @id_required

  def google_args(extra), do: Map.merge(@google_account, extra)

  def list_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: %{}}

  def get_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: @id_required}

  # Deletes are irreversible, so they are `gated`: an autonomous run working
  # untrusted-origin content (`:agent_untrusted`) cannot fire them — they surface
  # for human approval instead. See `command_gated?/1` and `PolicyEngine.check/1`.
  def delete_entry(name, desc),
    do: %{
      name: name,
      type: :mutate,
      tier: :restricted,
      gated: true,
      description: desc,
      args: @id_required
    }

  def id_trigger_entry(name, desc, tier),
    do: %{name: name, type: :trigger, tier: tier, description: desc, args: @id_required}
end
