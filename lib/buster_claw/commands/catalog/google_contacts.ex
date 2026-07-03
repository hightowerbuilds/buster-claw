defmodule BusterClaw.Commands.Catalog.GoogleContacts do
  @moduledoc "Catalog entries: Google Contacts (People)."

  alias BusterClaw.Commands.Catalog.Helpers

  @doc "Contacts (People) catalog entries."
  def entries,
    do: [
      # Contacts (People)
      %{
        name: "contacts_list",
        type: :read,
        tier: :safe,
        description: "List the account's Google Contacts.",
        args:
          Helpers.google_args(%{
            "page_size" => %{type: :integer, required: false, default: 100},
            "page_token" => %{type: :string, required: false},
            "sync_token" => %{type: :string, required: false}
          })
      },
      %{
        name: "contacts_search",
        type: :read,
        tier: :safe,
        description: "Search the account's Google Contacts.",
        args:
          Helpers.google_args(%{
            "query" => %{type: :string, required: true}
          })
      },
      %{
        name: "contacts_get",
        type: :read,
        tier: :safe,
        description: "Get one contact by resource name (e.g. people/c123).",
        args:
          Helpers.google_args(%{
            "resource_name" => %{type: :string, required: true}
          })
      },
      %{
        name: "contacts_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Create a contact. Provide a raw `contact` Person resource, or given_name/family_name/contact_email/phone.",
        args:
          Helpers.google_args(%{
            "contact" => %{type: :object, required: false},
            "given_name" => %{type: :string, required: false},
            "family_name" => %{type: :string, required: false},
            "contact_email" => %{type: :string, required: false},
            "phone" => %{type: :string, required: false}
          })
      },
      %{
        name: "contacts_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a contact. Requires the current etag (from contacts_get).",
        args:
          Helpers.google_args(%{
            "resource_name" => %{type: :string, required: true},
            "etag" => %{type: :string, required: true},
            "contact" => %{type: :object, required: false},
            "given_name" => %{type: :string, required: false},
            "family_name" => %{type: :string, required: false},
            "contact_email" => %{type: :string, required: false},
            "phone" => %{type: :string, required: false}
          })
      },
      %{
        name: "contacts_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Delete a contact (irreversible).",
        args:
          Helpers.google_args(%{
            "resource_name" => %{type: :string, required: true}
          })
      }
    ]
end
