defmodule BusterClaw.Repo.Migrations.AddDispatchRfcMessageId do
  use Ecto.Migration

  # The RFC 5322 Message-ID of the source email (distinct from the Gmail API id
  # in `gmail_message_id`). Stored so a reply can thread via In-Reply-To /
  # References without re-fetching the original message.
  def change do
    alter table(:dispatch_items) do
      add :gmail_rfc_message_id, :string
    end
  end
end
