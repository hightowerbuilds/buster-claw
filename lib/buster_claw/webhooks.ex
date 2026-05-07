defmodule BusterClaw.Webhooks do
  @moduledoc "Local webhook configuration, authentication, and trigger auditing."

  import Bitwise
  import Ecto.Query

  alias BusterClaw.{Automation, Repo, Workflow}
  alias BusterClaw.Automation.Webhook

  def list_webhooks do
    Webhook
    |> order_by([webhook], asc: webhook.name)
    |> Repo.all()
  end

  def get_webhook!(id), do: Automation.get_webhook!(id)
  def get_by_name(name), do: Repo.get_by(Webhook, name: name)
  def create_webhook(attrs), do: Automation.create_webhook(attrs)
  def update_webhook(%Webhook{} = webhook, attrs), do: Automation.update_webhook(webhook, attrs)
  def delete_webhook(%Webhook{} = webhook), do: Automation.delete_webhook(webhook)

  def change_webhook(%Webhook{} = webhook \\ %Webhook{}, attrs \\ %{}),
    do: Webhook.changeset(webhook, attrs)

  def trigger(name, headers, body) do
    case get_by_name(name) do
      nil ->
        audit(name, "not_found", body)
        {:error, :not_found}

      %Webhook{enabled: false} = webhook ->
        audit(webhook, "disabled", body)
        {:error, :disabled}

      %Webhook{} = webhook ->
        if authorized?(webhook, headers) do
          audit(webhook, "accepted", body)
          {:ok, action_summary(webhook)}
        else
          audit(webhook, "unauthorized", body)
          {:error, :unauthorized}
        end
    end
  end

  def authorized?(%Webhook{secret: secret}, _headers) when secret in [nil, ""], do: true

  def authorized?(%Webhook{secret: secret}, headers) do
    candidates = [
      header(headers, "x-buster-claw-secret"),
      bearer_token(header(headers, "authorization"))
    ]

    Enum.any?(candidates, &secure_compare(secret, &1))
  end

  defp action_summary(webhook) do
    %{
      webhook: webhook.name,
      action: webhook.action,
      custom_cmd: webhook.custom_cmd,
      deliver_to: webhook.deliver_to
    }
  end

  defp audit(%Webhook{} = webhook, status, body) do
    Workflow.create_runtime_event(%{
      kind: "webhook.#{status}",
      message: "Webhook #{webhook.name} #{status}",
      metadata: %{
        "webhook_id" => webhook.id,
        "name" => webhook.name,
        "action" => webhook.action,
        "status" => status,
        "body_size" => byte_size(to_string(body))
      },
      occurred_at: timestamp()
    })
  end

  defp audit(name, status, body) do
    Workflow.create_runtime_event(%{
      kind: "webhook.#{status}",
      message: "Webhook #{name} #{status}",
      metadata: %{"name" => name, "status" => status, "body_size" => byte_size(to_string(body))},
      occurred_at: timestamp()
    })
  end

  defp header(headers, key) do
    headers
    |> Enum.find_value(fn {header, value} ->
      if String.downcase(header) == key, do: value
    end)
  end

  defp bearer_token("Bearer " <> token), do: token
  defp bearer_token("bearer " <> token), do: token
  defp bearer_token(_), do: nil

  defp secure_compare(expected, candidate) when is_binary(candidate) do
    expected = to_string(expected)

    if byte_size(expected) == byte_size(candidate) do
      expected
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(candidate))
      |> Enum.reduce(0, fn {left, right}, acc -> acc ||| bxor(left, right) end)
      |> Kernel.==(0)
    else
      false
    end
  end

  defp secure_compare(_expected, _candidate), do: false

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
