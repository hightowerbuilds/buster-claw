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
      Helpers.delete_entry("notify_delete", "Delete a notification."),
      # Spoken messages (VOICE_ROADMAP, 09-03). A message is a line rendered in the
      # operator's own voice and installed as a library sound; firing it is a
      # notification whose metadata names that sound. So the agent can leave the
      # operator a message in the operator's voice — "I finished the report" —
      # now, in N seconds, or at a moment.
      %{
        name: "voice_message_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Create or re-render a spoken message in the operator's voice. Returns at once with ready=false while the engine works (minutes on a slow machine); voice_message_list shows when the audio has landed. Needs the speech engine installed. name is a slug (letters, digits, dashes); text is what gets said.",
        args: %{
          "name" => %{type: :string, required: true},
          "text" => %{type: :string, required: true}
        }
      },
      Helpers.list_entry(
        "voice_message_list",
        "List spoken messages: name, text, whether the audio is ready, and whether it is installed as a sound."
      ),
      %{
        name: "voice_message_fire",
        type: :mutate,
        tier: :restricted,
        description:
          "Fire a spoken message as a notification — the room hears the operator's own voice say it, and the modal shows the words. Now by default; in_seconds makes it a timer, at (ISO-8601) an alarm. Refuses a message whose audio is not ready yet (not_ready).",
        args: %{
          "name" => %{type: :string, required: true},
          "in_seconds" => %{type: :integer, required: false},
          "at" => %{type: :string, required: false}
        }
      },
      %{
        name: "voice_message_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a spoken message and its library sound.",
        args: %{"name" => %{type: :string, required: true}}
      }
    ]
end
