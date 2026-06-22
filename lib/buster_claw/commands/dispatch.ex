defmodule BusterClaw.Commands.Dispatch do
  @moduledoc """
  Dispatch-queue commands (the pull model): list/show/claim queued items, mark
  them done/blocked, set execution strategy, and send a threaded Gmail reply.
  Delegated to from `BusterClaw.Commands`.

  The reply path reuses `BusterClaw.Commands.Google.with_google_account/2` for
  account resolution rather than duplicating it.
  """

  import BusterClaw.Commands.Helpers

  alias BusterClaw.Dispatch
  alias BusterClaw.Commands.Google
  alias BusterClaw.Google.Gmail

  def dispatch_list(args \\ %{}) do
    items =
      case blank_to_nil(Map.get(args, "status")) do
        nil -> Dispatch.list_open()
        status -> Dispatch.list_items(status: status, limit: Map.get(args, "limit"))
      end

    {:ok, filter_by_job(items, blank_to_nil(Map.get(args, "job")))}
  end

  def dispatch_show(%{"id" => id}), do: safe_get(Dispatch, :get_item!, id)

  def dispatch_claim(args \\ %{}) do
    claimed_by =
      blank_to_nil(Map.get(args, "claimed_by")) || blank_to_nil(Map.get(args, "job")) || "agent"

    opts =
      [source: blank_to_nil(Map.get(args, "source")), role: blank_to_nil(Map.get(args, "job"))]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Dispatch.claim_next(claimed_by, opts) do
      {:ok, item} -> {:ok, item}
      {:error, :empty} -> {:ok, %{"empty" => true}}
      {:error, reason} -> {:error, reason}
    end
  end

  def dispatch_done(%{"id" => id} = args), do: finish_dispatch(id, "done", args)
  def dispatch_block(%{"id" => id} = args), do: finish_dispatch(id, "blocked", args)

  @doc """
  Set a queued item's execution strategy (`single` | `swarm`). `swarm` opts the
  item into the Phase 4 coordinator (parallel fan-out); only a still-queued item
  may be re-targeted.
  """
  def dispatch_strategy(%{"id" => id} = args) do
    with_resource(Dispatch, :get_item!, id, fn item ->
      case blank_to_nil(Map.get(args, "strategy")) do
        s when s in ["single", "swarm"] -> Dispatch.set_strategy(item, s)
        _ -> {:error, :bad_strategy}
      end
    end)
  end

  @doc """
  Send a threaded Gmail reply to a Dispatch item's sender and mark the item done.
  Restricted-tier: the act of calling it is the send authorization (no separate
  `confirm_send`). The reply threads via the stored RFC Message-ID + thread id and
  is sent from the account that received the original mail.
  """
  def dispatch_reply(%{"id" => id} = args) do
    with_resource(Dispatch, :get_item!, id, fn item ->
      cond do
        is_nil(blank_to_nil(Map.get(args, "body"))) -> {:error, :missing_body}
        is_nil(blank_to_nil(item.sender)) -> {:error, :no_reply_recipient}
        true -> send_dispatch_reply(item, blank_to_nil(Map.get(args, "body")), args)
      end
    end)
  end

  defp send_dispatch_reply(item, body, args) do
    selector =
      args
      |> Map.take(["account_id", "email"])
      |> put_new_string("email", blank_to_nil(item.source_account))

    Google.with_google_account(selector, fn account ->
      case Gmail.send_message(account, reply_message_attrs(item, body)) do
        {:ok, sent} ->
          # The mail is already sent. If finishing the Dispatch item fails we must
          # NOT crash and report the whole reply as failed — surface the partial
          # success instead so the caller knows the send went through.
          thread_id = Map.get(sent, :thread_id) || item.gmail_thread_id

          BusterClaw.Sentinel.observe(
            :outbound_send,
            "Auto-replied to Dispatch item ##{item.id}",
            %{
              dispatch_item_id: item.id,
              to: item.sender,
              gmail_thread_id: item.gmail_thread_id
            }
          )

          case Dispatch.finish(item, "done", reply_finish_attrs(body)) do
            {:ok, finished} ->
              {:ok,
               %{
                 dispatch_item_id: finished.id,
                 status: finished.status,
                 to: item.sender,
                 subject: reply_subject(item.subject),
                 thread_id: thread_id
               }}

            {:error, reason} ->
              # Sent, but the item could not be marked done. Report partial success
              # rather than raising a MatchError.
              {:ok,
               %{
                 dispatch_item_id: item.id,
                 status: item.status,
                 sent: true,
                 finish_error: reason,
                 to: item.sender,
                 subject: reply_subject(item.subject),
                 thread_id: thread_id
               }}
          end

        error ->
          error
      end
    end)
  end

  defp reply_message_attrs(item, body) do
    %{
      "to" => item.sender,
      "subject" => reply_subject(item.subject),
      "body" => body,
      "in_reply_to" => item.gmail_rfc_message_id,
      "references" => item.gmail_rfc_message_id,
      "thread_id" => item.gmail_thread_id
    }
  end

  defp reply_subject(subject) do
    case blank_to_nil(subject) do
      nil -> "Re:"
      trimmed -> if Regex.match?(~r/^re:/i, trimmed), do: trimmed, else: "Re: " <> trimmed
    end
  end

  defp reply_finish_attrs(body) do
    %{outcome: "replied", notes: "Auto-replied: " <> String.slice(to_string(body), 0, 280)}
  end

  defp put_new_string(map, _key, nil), do: map

  defp put_new_string(map, key, value) do
    if Map.get(map, key) in [nil, ""], do: Map.put(map, key, value), else: map
  end

  defp finish_dispatch(id, status, args) do
    with_resource(Dispatch, :get_item!, id, fn item ->
      attrs =
        case blank_to_nil(Map.get(args, "note")) do
          nil -> %{}
          note -> %{notes: note, outcome: note}
        end

      Dispatch.finish(item, status, attrs)
    end)
  end

  defp filter_by_job(items, nil), do: items
  defp filter_by_job(items, job), do: Enum.filter(items, &(&1.recommended_role_key == job))
end
