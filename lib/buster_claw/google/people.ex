defmodule BusterClaw.Google.People do
  @moduledoc "Google People (Contacts) read/write helpers for connected accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client

  @people_base_url "https://people.googleapis.com/v1"
  @default_person_fields "names,emailAddresses,phoneNumbers,organizations"
  @default_page_size 100

  @doc "List the account's contacts (`people.connections.list`)."
  def list(%Account{} = account, opts \\ []) do
    params =
      [
        {"personFields", person_fields(opts)},
        {"pageSize", opts |> Keyword.get(:page_size, @default_page_size) |> to_string()}
      ]
      |> put_present("pageToken", Keyword.get(opts, :page_token))
      |> put_present("syncToken", Keyword.get(opts, :sync_token))

    with {:ok, body} <- get(account, "people/me/connections", params, opts) do
      {:ok,
       %{
         contacts: body |> Map.get("connections", []) |> Enum.map(&contact_summary/1),
         next_page_token: Map.get(body, "nextPageToken"),
         next_sync_token: Map.get(body, "nextSyncToken"),
         total: Map.get(body, "totalpeople") || Map.get(body, "totalItems")
       }}
    end
  end

  @doc "Search the account's contacts (`people:searchContacts`)."
  def search(%Account{} = account, query, opts \\ []) do
    params = [{"query", query}, {"readMask", person_fields(opts)}]

    with {:ok, body} <- get(account, "people:searchContacts", params, opts) do
      contacts =
        body
        |> Map.get("results", [])
        |> Enum.map(fn result -> result |> Map.get("person", %{}) |> contact_summary() end)

      {:ok, %{contacts: contacts}}
    end
  end

  @doc "Fetch one contact by resource name (e.g. `people/c123`)."
  def get(%Account{} = account, resource_name, opts \\ []) when is_binary(resource_name) do
    params = [{"personFields", person_fields(opts)}]

    with {:ok, body} <- get(account, resource_name, params, opts) do
      {:ok, contact_summary(body)}
    end
  end

  @doc "Create a contact (`people.createContact`). `attrs` is a Person resource."
  def create(%Account{} = account, attrs, opts \\ []) when is_map(attrs) do
    opts = Keyword.put(opts, :base_url, @people_base_url)

    with {:ok, body} <- Client.post_json(account, "people:createContact", attrs, opts) do
      {:ok, contact_summary(body)}
    end
  end

  @doc """
  Update a contact (`people.updateContact`). Google requires the current `etag`
  (echoed back in the body) and an `updatePersonFields` mask of what changed.
  """
  def update(%Account{} = account, resource_name, attrs, etag, opts \\ []) when is_map(attrs) do
    params = [{"updatePersonFields", update_person_fields(opts)}]
    opts = opts |> Keyword.put(:base_url, @people_base_url) |> Keyword.put(:params, params)
    body = Map.put(attrs, "etag", etag)

    with {:ok, body} <-
           Client.patch_json(account, "#{resource_name}:updateContact", body, opts) do
      {:ok, contact_summary(body)}
    end
  end

  @doc "Delete a contact (`people.deleteContact`, irreversible)."
  def delete(%Account{} = account, resource_name, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @people_base_url)

    with {:ok, _} <- Client.delete(account, "#{resource_name}:deleteContact", opts) do
      {:ok, %{resource_name: resource_name, deleted: true}}
    end
  end

  defp get(account, path, params, opts) do
    opts = opts |> Keyword.put(:base_url, @people_base_url) |> Keyword.put(:params, params)
    Client.get_json(account, path, opts)
  end

  defp person_fields(opts), do: Keyword.get(opts, :person_fields, @default_person_fields)

  defp update_person_fields(opts),
    do: Keyword.get(opts, :update_person_fields, @default_person_fields)

  defp contact_summary(person) do
    %{
      resource_name: Map.get(person, "resourceName"),
      etag: Map.get(person, "etag"),
      display_name: get_in(person, ["names", Access.at(0), "displayName"]),
      names: Map.get(person, "names", []),
      email_addresses: Map.get(person, "emailAddresses", []),
      phone_numbers: Map.get(person, "phoneNumbers", []),
      organizations: Map.get(person, "organizations", []),
      raw: person
    }
  end

  defp put_present(params, _key, value) when value in [nil, ""], do: params
  defp put_present(params, key, value), do: params ++ [{key, to_string(value)}]
end
