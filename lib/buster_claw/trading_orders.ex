defmodule BusterClaw.TradingOrders do
  @moduledoc """
  Application-owned equity order workflow.

  Natural language may create a draft, but it can never call the broker. Only a
  structured broker review followed by an exact, unexpired confirmation can
  claim an idempotency key and cross the submission boundary.
  """

  import Ecto.Query

  alias BusterClaw.Repo
  alias BusterClaw.TradingBroker
  alias BusterClaw.TradingOrders.Broker.Disabled
  alias BusterClaw.TradingOrders.OrderEvent
  alias BusterClaw.TradingOrders.OrderIntent
  alias BusterClaw.TradingOrders.Policy

  @confirmation_ttl_seconds 120
  @terminal_statuses ~w(filled rejected cancelled failed)
  @symbol_re ~r/\A[A-Z][A-Z0-9.]{0,9}\z/
  @quantity_re ~r/\A\d+(?:\.\d{1,6})?\z/
  @money_re ~r/\A\d+(?:\.\d{1,2})?\z/

  @doc """
  Parse the intentionally narrow `/order` grammar into a non-executable draft.

  Examples:

      /order buy 2 AAPL market day account=agentic_opaque_id
      /order sell 1.5 AAPL limit 220.25 gtc account=agentic_opaque_id
      /order buy $250 AAPL market day account=agentic_opaque_id
  """
  def parse_command(text) when is_binary(text) do
    trimmed = String.trim(text)

    with [body, account_id] <- String.split(trimmed, ~r/\s+account=/, parts: 2),
         true <- String.starts_with?(body, "/order "),
         {:ok, attrs} <- parse_order_tokens(String.split(body)),
         true <- account_id != "" and not Regex.match?(~r/\s/, account_id) do
      {:ok, Map.put(attrs, "account_id", account_id)}
    else
      _error -> {:error, :invalid_order_command}
    end
  end

  def parse_command(_text), do: {:error, :invalid_order_command}

  @doc "Persist a validated non-executable order draft and its creation event."
  def create_draft(attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs) do
      Repo.transaction(fn ->
        changeset =
          OrderIntent.draft_changeset(
            %OrderIntent{},
            Map.merge(normalized, %{
              public_id: Ecto.UUID.generate(),
              client_order_id: Ecto.UUID.generate(),
              status: "draft"
            })
          )

        case Repo.insert(changeset) do
          {:ok, intent} ->
            insert_event!(intent, "draft_created", request_payload(intent))
            intent

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  def create_draft(_attrs), do: {:error, :invalid_order}

  @doc """
  Ask the structured broker adapter for a current review and bind confirmation
  to the resulting exact payload.
  """
  def preview(public_id, opts \\ []) when is_binary(public_id) do
    broker = Keyword.get(opts, :broker, configured_review_broker())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl = Keyword.get(opts, :confirmation_ttl_seconds, @confirmation_ttl_seconds)

    with %OrderIntent{status: "draft"} = intent <- get(public_id),
         {:ok, raw_review} <- broker.review(request_payload(intent)),
         {:ok, review} <- validate_review(raw_review),
         :ok <- Policy.check(intent, review, Keyword.put(opts, :now, now)) do
      persist_preview(intent, review, now, ttl)
    else
      nil -> {:error, :not_found}
      %OrderIntent{} -> {:error, :order_not_draft}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_broker_review}
    end
  end

  @doc """
  Atomically claim a preview for submission, then call the broker once with the
  stored client order id. Replays cannot cross the state transition.
  """
  def confirm_and_submit(public_id, preview_digest, phrase, opts \\ [])

  def confirm_and_submit(public_id, preview_digest, phrase, opts)
      when is_binary(public_id) and is_binary(preview_digest) and is_binary(phrase) do
    broker = Keyword.get(opts, :broker, configured_broker())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, intent} <- claim_submission(public_id, preview_digest, phrase, now) do
      finish_submission(intent, broker.submit(intent, intent.client_order_id), now)
    end
  end

  def confirm_and_submit(_public_id, _preview_digest, _phrase, _opts),
    do: {:error, :invalid_confirmation}

  @doc "Refresh a nonterminal broker status and append the returned transition."
  def reconcile(public_id, opts \\ []) when is_binary(public_id) do
    broker = Keyword.get(opts, :broker, configured_broker())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case get(public_id) do
      nil ->
        {:error, :not_found}

      %OrderIntent{status: status} when status in @terminal_statuses ->
        {:ok, get(public_id)}

      %OrderIntent{status: status} = intent
      when status in ["submitting", "accepted", "unknown"] ->
        case broker.fetch_order(intent) do
          {:ok, %{status: status, response: response}}
          when is_binary(status) and is_map(response) ->
            persist_reconciliation(intent, status, response, now)

          {:error, reason} ->
            {:error, reason}

          _other ->
            {:error, :invalid_broker_response}
        end

      %OrderIntent{} ->
        {:error, :order_not_submitted}
    end
  end

  @doc "Cancel an unsubmitted preview locally and record the transition."
  def cancel_preview(public_id) when is_binary(public_id) do
    case get(public_id) do
      nil ->
        {:error, :not_found}

      %OrderIntent{status: "previewed"} = intent ->
        update_with_event(
          intent,
          %{status: "cancelled", failure_reason: nil},
          "preview_cancelled",
          %{"preview_digest" => intent.preview_digest}
        )

      %OrderIntent{} ->
        {:error, :order_not_previewed}
    end
  end

  def get(public_id) when is_binary(public_id),
    do: Repo.get_by(OrderIntent, public_id: public_id)

  def events(public_id) when is_binary(public_id) do
    from(e in OrderEvent,
      join: i in assoc(e, :order_intent),
      where: i.public_id == ^public_id,
      order_by: [asc: e.occurred_at, asc: e.id]
    )
    |> Repo.all()
  end

  def recent(limit \\ 20) when is_integer(limit) and limit > 0 and limit <= 100 do
    OrderIntent
    |> order_by([i], desc: i.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Reconcile a bounded batch of submitted orders that are not terminal yet."
  def reconcile_pending(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    intents =
      OrderIntent
      |> where([i], i.status in ["submitting", "accepted", "unknown"])
      |> order_by([i], asc: i.last_reconciled_at, asc: i.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    results =
      intents
      |> Task.async_stream(&reconcile(&1.public_id, opts),
        ordered: false,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:reconciliation_exit, reason}}
      end)

    {:ok,
     %{
       attempted: length(intents),
       reconciled: Enum.count(results, &match?({:ok, _intent}, &1)),
       errors: Enum.count(results, &match?({:error, _reason}, &1))
     }}
  end

  @doc "True only when both a structured broker and opaque trading account are configured."
  def execution_ready? do
    configured_broker() != Disabled and match?({:ok, _account}, configured_account())
  end

  @doc "True when structured broker review is available; this does not imply submission."
  def review_ready? do
    configured_review_broker() != Disabled and match?({:ok, _account}, configured_account())
  end

  @doc "The configured opaque account identity used by the structured order lane."
  def configured_account do
    case Application.get_env(:buster_claw, :trading_order_account) do
      %{id: id} = account when is_binary(id) and byte_size(id) >= 8 ->
        {:ok, %{id: id, label: Map.get(account, :label, "Trading account")}}

      %{"id" => id} = account when is_binary(id) and byte_size(id) >= 8 ->
        {:ok, %{id: id, label: Map.get(account, "label", "Trading account")}}

      _other ->
        case TradingBroker.agentic_account() do
          %{account_key: id, label: label} when is_binary(id) and byte_size(id) >= 8 ->
            {:ok, %{id: id, label: label}}

          _other ->
            {:error, :structured_trading_account_not_configured}
        end
    end
  end

  @doc "The exact phrase a user must type for a returned preview."
  def confirmation_phrase(%OrderIntent{} = intent) do
    quantity =
      if intent.quantity_micros,
        do: format_quantity(intent.quantity_micros),
        else: "$#{format_cents(intent.notional_cents)}"

    "CONFIRM #{String.upcase(intent.side)} #{quantity} #{intent.symbol} " <>
      String.slice(intent.preview_digest || "", 0, 8)
  end

  defp parse_order_tokens(["/order", side, amount, symbol, "market", tif])
       when side in ["buy", "sell"] and tif in ["day", "gtc"] do
    amount_attrs(amount, %{
      "side" => side,
      "symbol" => String.upcase(symbol),
      "order_type" => "market",
      "time_in_force" => tif
    })
  end

  defp parse_order_tokens(["/order", side, amount, symbol, "limit", price, tif])
       when side in ["buy", "sell"] and tif in ["day", "gtc"] do
    amount_attrs(amount, %{
      "side" => side,
      "symbol" => String.upcase(symbol),
      "order_type" => "limit",
      "limit_price" => price,
      "time_in_force" => tif
    })
  end

  defp parse_order_tokens(_tokens), do: {:error, :invalid_order_command}

  defp amount_attrs("$" <> notional, attrs),
    do: {:ok, Map.merge(attrs, %{"amount_type" => "notional", "amount" => notional})}

  defp amount_attrs(quantity, attrs),
    do: {:ok, Map.merge(attrs, %{"amount_type" => "quantity", "amount" => quantity})}

  defp normalize_attrs(attrs) do
    account_id = value(attrs, :account_id)
    account_label = value(attrs, :account_label)
    symbol = value(attrs, :symbol) |> normalize_string() |> String.upcase()
    side = value(attrs, :side) |> normalize_string() |> String.downcase()
    order_type = value(attrs, :order_type) |> normalize_string() |> String.downcase()
    time_in_force = value(attrs, :time_in_force) |> normalize_string() |> String.downcase()
    amount_type = value(attrs, :amount_type) |> normalize_string() |> String.downcase()
    amount = value(attrs, :amount) |> normalize_string()
    limit_price = value(attrs, :limit_price) |> normalize_string()

    with true <- is_binary(account_id) and byte_size(String.trim(account_id)) >= 8,
         true <- Regex.match?(@symbol_re, symbol),
         true <- side in ["buy", "sell"],
         true <- order_type in ["market", "limit"],
         true <- time_in_force in ["day", "gtc"],
         {:ok, amount_fields} <- parse_amount(amount_type, amount),
         {:ok, limit_price_cents} <- parse_limit(order_type, limit_price) do
      {:ok,
       Map.merge(amount_fields, %{
         account_id: String.trim(account_id),
         account_label: blank_to_nil(account_label),
         symbol: symbol,
         side: side,
         order_type: order_type,
         limit_price_cents: limit_price_cents,
         time_in_force: time_in_force
       })}
    else
      _error -> {:error, :invalid_order}
    end
  end

  defp parse_amount("quantity", amount) do
    case decimal_to_integer(amount, @quantity_re, 6) do
      {:ok, micros} when micros > 0 ->
        {:ok, %{quantity_micros: micros, notional_cents: nil}}

      _error ->
        {:error, :invalid_quantity}
    end
  end

  defp parse_amount("notional", amount) do
    case decimal_to_integer(amount, @money_re, 2) do
      {:ok, cents} when cents > 0 ->
        {:ok, %{quantity_micros: nil, notional_cents: cents}}

      _error ->
        {:error, :invalid_notional}
    end
  end

  defp parse_amount(_type, _amount), do: {:error, :invalid_amount_type}

  defp parse_limit("market", ""), do: {:ok, nil}
  defp parse_limit("market", _value), do: {:error, :market_order_has_limit}

  defp parse_limit("limit", value) do
    case decimal_to_integer(value, @money_re, 2) do
      {:ok, cents} when cents > 0 -> {:ok, cents}
      _error -> {:error, :invalid_limit_price}
    end
  end

  defp decimal_to_integer(value, regex, scale) do
    if Regex.match?(regex, value) do
      [whole | fractional] = String.split(value, ".", parts: 2)
      decimals = fractional |> List.first("") |> String.pad_trailing(scale, "0")
      {:ok, String.to_integer(whole) * trunc(:math.pow(10, scale)) + String.to_integer(decimals)}
    else
      {:error, :invalid_decimal}
    end
  end

  defp persist_preview(intent, review, now, ttl) do
    expires_at = DateTime.add(now, ttl, :second)
    payload = preview_payload(intent, review, expires_at)
    digest = digest(payload)

    previewed =
      Ecto.Changeset.change(intent, %{
        status: "previewed",
        quote_cents: review.quote_cents,
        buying_power_cents: review.buying_power_cents,
        estimated_notional_cents: review.estimated_notional_cents,
        concentration_bps: review.concentration_bps,
        broker_preview: review.broker_preview,
        broker_preview_id: review.broker_preview_id,
        broker_timestamp: review.broker_timestamp,
        preview_payload: payload,
        preview_digest: digest,
        confirmation_digest: digest(confirmation_phrase_for(intent, digest)),
        confirmation_expires_at: expires_at
      })

    Repo.transaction(fn ->
      case Repo.update(previewed) do
        {:ok, updated} ->
          insert_event!(updated, "preview_created", %{
            "preview_digest" => digest,
            "expires_at" => DateTime.to_iso8601(expires_at),
            "payload" => payload
          })

          %{intent: updated, confirmation_phrase: confirmation_phrase(updated)}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp claim_submission(public_id, preview_digest, phrase, now) do
    result =
      Repo.transaction(fn ->
        case get(public_id) do
          nil ->
            Repo.rollback(:not_found)

          %OrderIntent{status: status} when status != "previewed" ->
            Repo.rollback(:confirmation_replayed)

          %OrderIntent{} = intent ->
            claim_preview(intent, preview_digest, phrase, now)
        end
      end)

    case result do
      {:ok, {:refused, reason}} -> {:error, reason}
      other -> other
    end
  end

  defp claim_preview(intent, preview_digest, phrase, now) do
    with true <- intent.preview_digest == preview_digest,
         true <- DateTime.compare(intent.confirmation_expires_at, now) == :gt,
         true <- secure_digest_match?(intent.confirmation_digest, phrase),
         {1, _rows} <-
           from(i in OrderIntent,
             where: i.id == ^intent.id and i.status == "previewed"
           )
           |> Repo.update_all(set: [status: "submitting", confirmed_at: now, updated_at: now]) do
      claimed = Repo.get!(OrderIntent, intent.id)

      insert_event!(claimed, "confirmation_accepted", %{
        "preview_digest" => preview_digest,
        "client_order_id" => claimed.client_order_id
      })

      claimed
    else
      false ->
        refuse_confirmation(intent, preview_digest, now)

      {0, _rows} ->
        Repo.rollback(:confirmation_replayed)
    end
  end

  defp refuse_confirmation(intent, preview_digest, now) do
    case classify_confirmation_failure(intent, preview_digest, now) do
      :confirmation_expired = reason ->
        {:ok, expired} = intent |> Ecto.Changeset.change(status: "expired") |> Repo.update()
        insert_event!(expired, "confirmation_expired", %{"preview_digest" => preview_digest})
        {:refused, reason}

      reason ->
        Repo.rollback(reason)
    end
  end

  defp classify_confirmation_failure(intent, preview_digest, now) do
    cond do
      intent.preview_digest != preview_digest -> :preview_tampered
      DateTime.compare(intent.confirmation_expires_at, now) != :gt -> :confirmation_expired
      true -> :confirmation_phrase_mismatch
    end
  end

  defp finish_submission(intent, {:ok, result}, now) do
    case result do
      %{broker_order_id: broker_id, status: broker_status, response: response}
      when is_binary(broker_id) and is_binary(broker_status) and is_map(response) ->
        local_status = local_status(broker_status)

        update_with_event(
          intent,
          %{
            status: local_status,
            broker_order_id: broker_id,
            broker_status: broker_status,
            broker_response: response,
            submitted_at: now,
            last_reconciled_at: now,
            failure_reason: nil
          },
          "broker_submission_recorded",
          %{
            "broker_order_id" => broker_id,
            "broker_status" => broker_status,
            "response" => response
          }
        )

      _other ->
        finish_submission(intent, {:error, {:unknown, :invalid_broker_response}}, now)
    end
  end

  defp finish_submission(intent, {:error, {certainty, reason}}, now)
       when certainty in [:definitive, :unknown] do
    status = if certainty == :unknown, do: "unknown", else: "rejected"
    rendered_reason = render_reason(reason)

    update_with_event(
      intent,
      %{
        status: status,
        failure_reason: rendered_reason,
        submitted_at: now,
        last_reconciled_at: now
      },
      "broker_submission_#{status}",
      %{"reason" => rendered_reason}
    )
  end

  defp finish_submission(intent, _other, now),
    do: finish_submission(intent, {:error, {:unknown, :invalid_broker_response}}, now)

  defp persist_reconciliation(intent, broker_status, response, now) do
    update_with_event(
      intent,
      %{
        status: local_status(broker_status),
        broker_status: broker_status,
        broker_response: response,
        last_reconciled_at: now,
        failure_reason: nil
      },
      "broker_status_reconciled",
      %{"broker_status" => broker_status, "response" => response}
    )
  end

  defp update_with_event(intent, changes, event_type, event_payload) do
    Repo.transaction(fn ->
      case intent |> Ecto.Changeset.change(changes) |> Repo.update() do
        {:ok, updated} ->
          insert_event!(updated, event_type, event_payload)
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp validate_review(
         %{
           quote_cents: quote,
           buying_power_cents: buying_power,
           estimated_notional_cents: notional,
           concentration_bps: concentration,
           market_open: market_open?,
           broker_preview: preview,
           broker_preview_id: preview_id,
           broker_timestamp: %DateTime{} = timestamp
         } = review
       )
       when is_integer(quote) and quote > 0 and is_integer(buying_power) and
              buying_power >= 0 and is_integer(notional) and notional > 0 and
              is_integer(concentration) and concentration >= 0 and concentration <= 10_000 and
              is_boolean(market_open?) and
              is_map(preview) and is_binary(preview_id) and preview_id != "" do
    {:ok,
     Map.merge(review, %{
       quote_cents: quote,
       buying_power_cents: buying_power,
       estimated_notional_cents: notional,
       concentration_bps: concentration,
       market_open: market_open?,
       broker_preview: preview,
       broker_preview_id: preview_id,
       broker_timestamp: timestamp
     })}
  end

  defp validate_review(_review), do: {:error, :invalid_broker_review}

  defp request_payload(intent) do
    %{
      "account_id" => intent.account_id,
      "symbol" => intent.symbol,
      "side" => intent.side,
      "quantity_micros" => intent.quantity_micros,
      "notional_cents" => intent.notional_cents,
      "order_type" => intent.order_type,
      "limit_price_cents" => intent.limit_price_cents,
      "time_in_force" => intent.time_in_force,
      "client_order_id" => intent.client_order_id
    }
  end

  defp preview_payload(intent, review, expires_at) do
    request_payload(intent)
    |> Map.merge(%{
      "quote_cents" => review.quote_cents,
      "buying_power_cents" => review.buying_power_cents,
      "estimated_notional_cents" => review.estimated_notional_cents,
      "concentration_bps" => review.concentration_bps,
      "market_open" => review.market_open,
      "broker_preview" => review.broker_preview,
      "broker_preview_id" => review.broker_preview_id,
      "broker_timestamp" => DateTime.to_iso8601(review.broker_timestamp),
      "confirmation_expires_at" => DateTime.to_iso8601(expires_at)
    })
  end

  defp insert_event!(intent, event_type, payload) do
    %OrderEvent{}
    |> OrderEvent.changeset(%{
      order_intent_id: intent.id,
      event_type: event_type,
      payload: payload,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp configured_broker do
    Application.get_env(:buster_claw, :trading_order_broker, Disabled)
  end

  defp configured_review_broker do
    case configured_broker() do
      Disabled ->
        Application.get_env(:buster_claw, :trading_order_review_broker, Disabled)

      execution_broker ->
        execution_broker
    end
  end

  defp local_status(status) do
    case String.downcase(status) do
      status when status in ["filled", "executed"] ->
        "filled"

      status when status in ["rejected", "failed"] ->
        "rejected"

      status when status in ["cancelled", "canceled"] ->
        "cancelled"

      status
      when status in [
             "new",
             "queued",
             "pending",
             "open",
             "confirmed",
             "partially_filled",
             "cancel_pending"
           ] ->
        "accepted"

      _other ->
        "unknown"
    end
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp secure_digest_match?(expected_digest, phrase)
       when is_binary(expected_digest) and is_binary(phrase) do
    Plug.Crypto.secure_compare(expected_digest, digest(phrase))
  end

  defp secure_digest_match?(_expected_digest, _phrase), do: false

  defp confirmation_phrase_for(intent, digest) do
    confirmation_phrase(%{intent | preview_digest: digest})
  end

  defp format_quantity(micros) do
    whole = div(micros, 1_000_000)
    decimal = micros |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    trimmed = String.trim_trailing(decimal, "0")
    if trimmed == "", do: Integer.to_string(whole), else: "#{whole}.#{trimmed}"
  end

  defp format_cents(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{dollars}.#{remainder}"
  end

  defp render_reason(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 500)

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: ""

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
