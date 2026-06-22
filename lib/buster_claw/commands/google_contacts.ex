defmodule BusterClaw.Commands.Google.Contacts do
  @moduledoc """
  Google Contacts (People API) command implementations: list/search/get plus
  create/update/delete.

  Account resolution and the generic argument validators come from
  `BusterClaw.Commands.Google.Accounts`; the `Person` resource builders are
  private here since only this module assembles contact payloads. The
  `BusterClaw.Commands.Google` facade delegates to these functions so dispatch
  still funnels through the single `Commands.call/2` choke point.
  """

  import BusterClaw.Commands.Google.Accounts,
    only: [with_google_account: 2, with_required: 4, put_attr: 3]

  alias BusterClaw.Google.People

  def contacts_list(args \\ %{}) do
    with_google_account(args, fn account ->
      People.list(account,
        page_size: Map.get(args, "page_size", 100),
        page_token: Map.get(args, "page_token"),
        sync_token: Map.get(args, "sync_token")
      )
    end)
  end

  def contacts_search(args) do
    with_required(args, "query", :missing_query, fn account, query ->
      People.search(account, query)
    end)
  end

  def contacts_get(args) do
    with_required(args, "resource_name", :missing_resource_name, fn account, resource_name ->
      People.get(account, resource_name)
    end)
  end

  def contacts_create(args) do
    case person_resource(args) do
      resource when resource == %{} ->
        {:error, :missing_contact}

      resource ->
        with_google_account(args, fn account ->
          People.create(account, resource)
        end)
    end
  end

  def contacts_update(args) do
    resource_name = Map.get(args, "resource_name")
    etag = Map.get(args, "etag")

    cond do
      resource_name in [nil, ""] ->
        {:error, :missing_resource_name}

      etag in [nil, ""] ->
        {:error, :missing_etag}

      true ->
        with_google_account(args, fn account ->
          People.update(account, resource_name, person_resource(args), etag)
        end)
    end
  end

  def contacts_delete(args) do
    with_required(args, "resource_name", :missing_resource_name, fn account, resource_name ->
      People.delete(account, resource_name)
    end)
  end

  # Build a People `Person` resource: a raw `contact` object wins; otherwise
  # assemble one from the flat convenience fields.
  defp person_resource(args) do
    case Map.get(args, "contact") do
      %{} = contact when contact != %{} -> contact
      _ -> build_person(args)
    end
  end

  defp build_person(args) do
    %{}
    |> put_person_name(args)
    |> put_person_field("emailAddresses", Map.get(args, "contact_email"))
    |> put_person_field("phoneNumbers", Map.get(args, "phone"))
  end

  defp put_person_name(person, args) do
    given = Map.get(args, "given_name")
    family = Map.get(args, "family_name")

    if given in [nil, ""] and family in [nil, ""] do
      person
    else
      name = %{} |> put_attr("givenName", given) |> put_attr("familyName", family)
      Map.put(person, "names", [name])
    end
  end

  defp put_person_field(person, _key, value) when value in [nil, ""], do: person

  defp put_person_field(person, "emailAddresses", value),
    do: Map.put(person, "emailAddresses", [%{"value" => value}])

  defp put_person_field(person, "phoneNumbers", value),
    do: Map.put(person, "phoneNumbers", [%{"value" => value}])
end
