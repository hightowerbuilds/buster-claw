defmodule BusterClaw.Agent.ThreadBinding do
  @moduledoc """
  Which backend thread or session a conversation last used, **per backend**.

  Keyed by `{conv_id, backend}` rather than by conversation alone, and that
  compound key is the whole point. A claude session, a codex thread, and an
  opencode session are three different conversations living on three different
  services. Storing one id per conversation would mean switching harness
  overwrote the id needed to switch back — the operator would return to a
  backend that had forgotten everything, which is exactly the continuity bug
  Phase 3 existed to fix.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "agent_chat_threads" do
    field :conv_id, :string, primary_key: true
    field :backend, :string, primary_key: true
    field :thread_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:conv_id, :backend, :thread_id])
    |> validate_required([:conv_id, :backend, :thread_id])
  end
end
