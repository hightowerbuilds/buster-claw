defmodule BusterClaw.Agent.Delivery do
  @moduledoc """
  One operator message's journey from the composer to a terminal state.

  The transcript records what was **said**; this records what happened to it.
  They are separate tables because they have opposite shapes: a transcript row
  is written once and never touched, while a delivery is updated several times
  between submission and its final state. Adding mutable columns to the
  transcript would cost it the one property it has.

  ## Statuses, and why `uncertain` exists

  | status | meaning |
  |---|---|
  | `pending` | accepted from the operator, not yet handed to a backend |
  | `sending` | handed over, no outcome yet |
  | `delivered` | the backend proved it took the message |
  | `queued` | it will run as its own turn, next — unfinished, and recovered |
  | `uncertain` | it left this machine and we cannot prove it arrived |
  | `failed` | it never left |

  `uncertain` is the one that earns its place. OpenCode's `prompt_async` returns
  an empty body, so a message can be genuinely in flight with no receipt — and
  a crash mid-send leaves the same ambiguity on any backend. **Recovery must
  never resend an uncertain row.** Applying an instruction twice is worse than
  dropping it once: the operator can retype a lost message, but cannot un-run a
  duplicated one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending sending delivered queued uncertain failed)
  @requested ~w(auto next steer)
  @effective ~w(started queued steered sent failed)

  # A terminal status is one recovery must not act on: the message's story is
  # over, whether or not it ended well.
  #
  # `queued` is deliberately NOT here. A queued message is unfinished work the
  # operator is still owed — it has to survive a restart and run afterwards,
  # which is the entire point of writing any of this down.
  @terminal ~w(delivered uncertain failed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :conv_id,
             :content,
             :requested_mode,
             :effective_mode,
             :status,
             :backend,
             :position,
             :accepted_at,
             :inserted_at
           ]}
  schema "agent_chat_deliveries" do
    field :conv_id, :string
    field :content, :string
    field :requested_mode, :string
    field :effective_mode, :string
    field :status, :string, default: "pending"
    field :backend, :string
    field :backend_thread_id, :string
    field :backend_turn_id, :string
    field :position, :integer
    field :accepted_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Statuses a recovery pass must leave alone."
  def terminal_statuses, do: @terminal

  @doc "True when this delivery's story is over."
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @doc """
  A new delivery, straight from the composer.

  `requested_mode` is what the operator asked for and is never rewritten —
  `effective_mode` carries what happened. Keeping both is what lets an audit
  answer "how often does a steer lose the race?", which one field cannot.
  """
  def new(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:conv_id, :content, :requested_mode, :position, :backend])
    |> validate_required([:conv_id, :content, :requested_mode])
    |> validate_inclusion(:requested_mode, @requested)
    |> put_change(:status, "pending")
  end

  @doc "Advance a delivery toward a terminal state."
  def transition(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :status,
      :effective_mode,
      :backend,
      :backend_thread_id,
      :backend_turn_id,
      :position,
      :accepted_at,
      :failed_at,
      :error
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:effective_mode, @effective)
    # Bounded: an error string is for a human reading the feed, not a place to
    # accumulate a stack trace.
    |> update_change(:error, &String.slice(&1, 0, 500))
  end
end
