defmodule BusterClaw.Repo.Migrations.CreateAgentChatDeliveries do
  use Ecto.Migration

  # The delivery ledger: what the operator submitted, how it was asked to be
  # delivered, and what actually happened to it.
  #
  # Deliberately NOT more columns on `agent_chat_messages`. That table is the
  # append-only transcript — what was SAID — and a delivery is a mutable fact
  # about how it travelled, updated several times between submission and a
  # terminal state. Mixing them would make the transcript no longer append-only,
  # which is the one property it has.
  def change do
    create table(:agent_chat_deliveries, primary_key: false) do
      # A server-generated UUID, carried by every retry and receipt. This is the
      # dedupe key: a double-click or a reconnect must produce one delivery, not
      # two, and all three backends can carry it natively (claude's replay,
      # codex's clientUserMessageId, opencode's messageID).
      add :id, :binary_id, primary_key: true

      add :conv_id, :string, null: false
      add :content, :text, null: false

      # What was asked for (auto | next | steer) versus what happened
      # (started | queued | steered | sent | failed). They differ whenever a
      # steer lost the race, and the difference is the whole reason both are
      # stored: the UI must render the second, and an audit needs the first.
      add :requested_mode, :string, null: false
      add :effective_mode, :string

      # pending -> sending -> (delivered | queued | failed), plus `uncertain`
      # for a message that left the machine with no proof it arrived. Recovery
      # must never blindly resend an uncertain row: applying an instruction
      # twice is worse than dropping it once.
      add :status, :string, null: false, default: "pending"

      add :backend, :string
      add :backend_thread_id, :string
      add :backend_turn_id, :string

      # Ordering within a conversation's pending queue. A race-demoted message
      # takes a position ahead of everything already waiting.
      add :position, :integer

      add :accepted_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :error, :string

      timestamps(type: :utc_datetime_usec)
    end

    # Boot recovery reads a conversation's unfinished rows in queue order, so
    # this is the index that matters.
    create index(:agent_chat_deliveries, [:conv_id, :status, :position])
    create index(:agent_chat_deliveries, [:status])

    # Which backend thread/session a conversation last used, PER BACKEND.
    #
    # Keyed by both because switching harness must not overwrite the id needed
    # when the operator switches back: a codex thread and a claude session are
    # different conversations on different services, and losing one to visit the
    # other is exactly the continuity bug Phase 3 just fixed.
    create table(:agent_chat_threads, primary_key: false) do
      add :conv_id, :string, null: false, primary_key: true
      add :backend, :string, null: false, primary_key: true
      add :thread_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
