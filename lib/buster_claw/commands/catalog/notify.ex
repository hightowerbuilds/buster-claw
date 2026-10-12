defmodule BusterClaw.Commands.Catalog.Notify do
  @moduledoc "Catalog entries: notifications (timers, alarms, reminders)."

  alias BusterClaw.Commands.Catalog.Helpers

  @doc "Notify catalog entries."
  def entries,
    do: [
      Helpers.list_entry("notify_list", "List upcoming notifications (pending + snoozed)."),
      Helpers.get_entry("notify_get", "Fetch a notification by ID."),
      %{
        name: "notify_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Schedule a notification. kind=timer needs in_seconds; kind=alarm needs at (ISO-8601); kind=reminder fires now.",
        args: %{
          "kind" => %{type: :string, required: false, enum: ["timer", "alarm", "reminder"]},
          "label" => %{type: :string, required: true},
          "in_seconds" => %{type: :integer, required: false},
          "at" => %{type: :string, required: false},
          "source" => %{
            type: :string,
            required: false,
            enum: ["chat", "terminal", "email", "voicemail", "manual"]
          },
          "metadata" => %{type: :map, required: false}
        }
      },
      %{
        name: "notify_snooze",
        type: :mutate,
        tier: :restricted,
        description: "Re-arm a notification (default 300 seconds).",
        args: %{
          "id" => %{type: :integer, required: true},
          "in_seconds" => %{type: :integer, required: false}
        }
      },
      %{
        name: "notify_dismiss",
        type: :mutate,
        tier: :restricted,
        description: "Retire a notification without firing it.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      Helpers.delete_entry("notify_delete", "Delete a notification.")
    ]
end
