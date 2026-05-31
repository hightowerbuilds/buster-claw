defmodule BusterClaw.Delivery do
  @moduledoc "Delivery destination management, dispatch, and test helpers."

  import Ecto.Query

  alias BusterClaw.{Automation, Repo, Workflow}
  alias BusterClaw.Automation.DeliveryDestination

  def list_destinations do
    DeliveryDestination
    |> order_by([destination], asc: destination.name)
    |> Repo.all()
  end

  def list_enabled_destinations do
    DeliveryDestination
    |> where([destination], destination.enabled == true)
    |> order_by([destination], asc: destination.name)
    |> Repo.all()
  end

  def get_destination!(id), do: Automation.get_delivery_destination!(id)

  def create_destination(attrs), do: Automation.create_delivery_destination(attrs)

  def update_destination(%DeliveryDestination{} = destination, attrs) do
    Automation.update_delivery_destination(destination, attrs)
  end

  def delete_destination(%DeliveryDestination{} = destination) do
    Automation.delete_delivery_destination(destination)
  end

  def change_destination(
        %DeliveryDestination{} = destination \\ %DeliveryDestination{},
        attrs \\ %{}
      ) do
    DeliveryDestination.changeset(destination, attrs)
  end

  def test_destination(%DeliveryDestination{} = destination, opts \\ []) do
    dispatch_destination(
      destination,
      %{
        title: Keyword.get(opts, :title, "Buster Claw delivery test"),
        body: Keyword.get(opts, :body, "Delivery destination test message.")
      },
      opts
    )
  end

  def dispatch_all(payload, opts \\ []) do
    list_enabled_destinations()
    |> Enum.map(&dispatch_destination(&1, payload, opts))
  end

  def dispatch_destination(%DeliveryDestination{} = destination, payload, opts \\ []) do
    started_at = timestamp()

    attempt =
      Workflow.create_delivery_attempt(%{
        delivery_destination_id: destination.id,
        report_id: Keyword.get(opts, :report_id),
        title: payload_title(payload),
        status: "sending",
        started_at: started_at
      })

    with {:ok, attempt} <- attempt do
      result = send_payload(destination, payload, opts)
      observe_send(destination, payload, result)
      finish_attempt(attempt, result)
    end
  end

  # A delivery leaves the box → record it on the Sentinel audit spine.
  defp observe_send(_destination, _payload, {:ok, :skipped}), do: :ok

  defp observe_send(destination, payload, result) do
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"

    BusterClaw.Sentinel.observe(
      :outbound_send,
      "Delivered \"#{payload_title(payload)}\" to #{destination.name} (#{outcome})",
      %{
        destination: destination.name,
        type: destination.type,
        url: destination.url,
        outcome: outcome
      }
    )
  end

  defp send_payload(%DeliveryDestination{enabled: false}, _payload, _opts) do
    {:error, "Destination is disabled"}
  end

  defp send_payload(%DeliveryDestination{url: nil}, _payload, _opts), do: {:ok, :skipped}
  defp send_payload(%DeliveryDestination{url: ""}, _payload, _opts), do: {:ok, :skipped}

  defp send_payload(%DeliveryDestination{} = destination, payload, opts) do
    req_options =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        method: :post,
        url: destination.url,
        headers: headers(destination),
        json: destination_payload(destination, payload)
      )

    case Req.request(req_options) do
      {:ok, response} when response.status in 200..299 -> {:ok, response.status}
      {:ok, response} -> {:error, "HTTP #{response.status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp finish_attempt(attempt, {:ok, _result}) do
    Workflow.update_delivery_attempt(attempt, %{
      status: "sent",
      error: nil,
      finished_at: timestamp()
    })
  end

  defp finish_attempt(attempt, {:error, reason}) do
    Workflow.update_delivery_attempt(attempt, %{
      status: "failed",
      error: bounded(to_string(reason)),
      finished_at: timestamp()
    })
  end

  defp destination_payload(destination, payload) do
    %{
      destination: %{
        id: destination.id,
        name: destination.name,
        type: destination.type,
        chat_id: destination.chat_id
      },
      message: payload
    }
  end

  defp headers(%DeliveryDestination{token: token}) when is_binary(token) and token != "" do
    [{"authorization", "Bearer #{token}"}]
  end

  defp headers(_destination), do: []

  defp payload_title(%{title: title}) when is_binary(title), do: title
  defp payload_title(%{"title" => title}) when is_binary(title), do: title
  defp payload_title(_payload), do: "Delivery"

  defp bounded(text, limit \\ 8_000) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit) <> "\n[truncated]",
      else: text
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
