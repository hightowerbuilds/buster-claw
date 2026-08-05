defmodule BusterClaw.TradingOrder do
  @moduledoc """
  The chat-native order proposal: parse one out of an assistant turn, and — only
  after the operator clicks confirm — submit it.

  ## Why this shape

  The trading chat runs with `Trading.read_only_cli_args/0`, an allowlist of
  `get_*` tools. That allowlist, not the system prompt, is what prevents the
  conversation from placing an order: an unlisted tool is refused by the agent
  process before the model can invoke it.

  Keeping that true is the whole design here. The conversational run never gains
  a write tool. It gathers side, symbol, quantity, order type, price and
  time-in-force in English — which is what a language model is genuinely good at
  — and then writes them into a fenced ```order block. Everything after that is
  the application's: this module parses the block, `TradingLive` renders the
  parsed values as a confirm card, and the operator's click calls `submit/1`,
  which spawns a SEPARATE one-shot run whose allowlist contains the write tool
  and whose parameters are literals from the struct.

  So the model proposes in prose and the app submits from a struct. A misread
  "sell 100" cannot become an order without the operator seeing "SELL 100 AAPL"
  rendered from the parsed value first.

  ## Double submission

  `AgentRunner` enforces a wall clock and kills the process group on timeout. It
  cannot know whether the broker accepted the order before the kill landed —
  neither can we. So a run that does not return a clean acceptance reports
  `:unknown` and says to check the broker; it never offers a retry. Re-sending
  is the one recovery this module will not automate.
  """

  alias BusterClaw.Agent.StreamEvent
  alias BusterClaw.AgentBackend
  alias BusterClaw.AgentRunner
  alias BusterClaw.ModelPolicy
  alias BusterClaw.Trading

  # get_accounts is here because placing needs a real account number and we
  # deliberately never persist one — the card carries last four digits, and the
  # submit run re-resolves them, exactly as the stage-2 detail prompt does.
  @submit_tools ~w(
    mcp__robinhood__get_accounts
    mcp__robinhood__place_equity_order
  )

  # A fenced block, not a JSON object loose in the prose: the fence is what makes
  # "here is what an order would look like" (an explanation) distinguishable from
  # "place this" (a proposal). A model discussing orders in the abstract does not
  # accidentally arm the confirm card.
  @fence_re ~r/```order\s*\n(?<body>.+?)\n?```/s

  @sides ~w(buy sell)
  @order_types ~w(market limit)
  @tifs ~w(day gtc)
  @symbol_re ~r/\A[A-Z][A-Z.]{0,6}\z/
  @last4_re ~r/\A\d{4}\z/

  @submit_timeout_ms 90_000

  @enforce_keys [:side, :symbol, :order_type, :time_in_force, :account_last4]
  defstruct [
    :side,
    :symbol,
    :order_type,
    :time_in_force,
    :account_last4,
    :quantity,
    :amount_usd,
    :limit_price
  ]

  @type t :: %__MODULE__{}

  @doc """
  Pull an order proposal out of an assistant message.

  `:none` when the turn contains no fenced order block — the overwhelmingly
  common case, and not an error. `{:error, reason}` when a block is present but
  will not validate: that IS worth surfacing, because the model tried to propose
  something and the app refused to render it.
  """
  @spec parse(String.t()) :: {:ok, t()} | :none | {:error, atom()}
  def parse(text) when is_binary(text) do
    case Regex.named_captures(@fence_re, text) do
      nil -> :none
      %{"body" => body} -> decode(body)
    end
  end

  def parse(_text), do: :none

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> validate(map)
      _error -> {:error, :unreadable_order_block}
    end
  end

  # Every field is checked here rather than trusted. The model produced this
  # JSON; it is untrusted input that happens to have come from our own prompt.
  defp validate(map) do
    with {:ok, side} <- enum(map, "side", @sides, {:missing_side, :invalid_side}),
         {:ok, symbol} <- symbol(map),
         {:ok, order_type} <-
           enum(map, "order_type", @order_types, {:missing_order_type, :invalid_order_type}),
         {:ok, tif} <-
           enum(map, "time_in_force", @tifs, {:missing_time_in_force, :invalid_time_in_force}),
         {:ok, last4} <- last4(map),
         {:ok, quantity, amount} <- size(map),
         {:ok, limit} <- limit_price(map, order_type) do
      {:ok,
       %__MODULE__{
         side: side,
         symbol: symbol,
         order_type: order_type,
         time_in_force: tif,
         account_last4: last4,
         quantity: quantity,
         amount_usd: amount,
         limit_price: limit
       }}
    end
  end

  # Errors are passed in rather than interpolated: `:"invalid_#{key}"` would mint
  # an atom at runtime from a value that ultimately came off the wire.
  defp enum(map, key, allowed, {missing, invalid}) do
    case map[key] do
      value when is_binary(value) ->
        downcased = String.downcase(String.trim(value))
        if downcased in allowed, do: {:ok, downcased}, else: {:error, invalid}

      _other ->
        {:error, missing}
    end
  end

  defp symbol(map) do
    with value when is_binary(value) <- map["symbol"],
         upcased <- value |> String.trim() |> String.upcase(),
         true <- Regex.match?(@symbol_re, upcased) do
      {:ok, upcased}
    else
      _error -> {:error, :invalid_symbol}
    end
  end

  defp last4(map) do
    with value when is_binary(value) <- to_string_or_nil(map["account_last4"]),
         true <- Regex.match?(@last4_re, value) do
      {:ok, value}
    else
      _error -> {:error, :invalid_account}
    end
  end

  # Shares or dollars, never both and never neither — an order that is ambiguous
  # about its own size is the exact mistake the confirm card exists to catch.
  defp size(map) do
    quantity = positive_number(map["quantity"])
    amount = positive_number(map["amount_usd"])

    case {quantity, amount} do
      {nil, nil} -> {:error, :missing_size}
      {_qty, _amt} when not is_nil(quantity) and not is_nil(amount) -> {:error, :ambiguous_size}
      {nil, amt} -> {:ok, nil, amt}
      {qty, nil} -> {:ok, qty, nil}
    end
  end

  defp limit_price(map, "limit") do
    case positive_number(map["limit_price"]) do
      nil -> {:error, :missing_limit_price}
      price -> {:ok, price}
    end
  end

  defp limit_price(map, "market") do
    # A market order carrying a price is not a market order. Rather than quietly
    # dropping the number the operator would have read on the card, refuse it.
    if is_nil(map["limit_price"]),
      do: {:ok, nil},
      else: {:error, :limit_price_on_market_order}
  end

  defp positive_number(value) when is_number(value) and value > 0, do: value * 1.0

  defp positive_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp positive_number(_value), do: nil

  defp to_string_or_nil(value) when is_binary(value), do: String.trim(value)
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(_value), do: nil

  @doc "One line describing the order, for the confirm card and the audit trail."
  def summary(%__MODULE__{} = order) do
    [
      String.upcase(order.side),
      size_phrase(order),
      order.symbol,
      type_phrase(order),
      String.upcase(order.time_in_force),
      "account ••••#{order.account_last4}"
    ]
    |> Enum.join(" · ")
  end

  defp size_phrase(%{quantity: nil, amount_usd: amount}), do: "$#{trim_number(amount)}"
  defp size_phrase(%{quantity: qty}), do: "#{trim_number(qty)} sh"

  defp type_phrase(%{order_type: "market"}), do: "MARKET"
  defp type_phrase(%{limit_price: price}), do: "LIMIT $#{trim_number(price)}"

  @doc "Render a float without a trailing `.0` — 2.0 shares reads as 2."
  def trim_number(number) when is_float(number) do
    if number == Float.round(number),
      do: number |> round() |> Integer.to_string(),
      else: number |> :erlang.float_to_binary([:short]) |> String.trim_trailing(".0")
  end

  @doc """
  Place the order. Only ever called from a confirm click, never from a chat turn.

  Returns `{:ok, broker_order_id}`, `{:error, {:refused, reason}}` when the
  broker declined cleanly, or `{:error, :unknown}` when the run did not come
  back with a readable verdict — see the double-submission note above.
  """
  @spec submit(t()) :: {:ok, String.t()} | {:error, {:refused, String.t()} | atom()}
  def submit(%__MODULE__{} = order) do
    # The same seam the Trading fetchers use, for the same reason: without it a
    # test of this path spawns a real claude run against a real brokerage.
    case Application.get_env(:buster_claw, :trading_order_submitter) do
      fun when is_function(fun, 1) -> fun.(order)
      _default -> run_submit(order)
    end
  end

  defp run_submit(order) do
    opts = [
      # See `Trading.run_agent/3`: `:order_submit` is pinned to claude, so these
      # are claude's flags by construction rather than by preference.
      extra_args: submit_cli_args() ++ AgentBackend.stream_args(:claude, stream: true),
      # The only path that moves money, and irreversible once the broker takes
      # it. `:order_submit` carries a `ModelPolicy` floor for the same reason
      # `:trading_read` does — on 07-28 a cheaper model on a money surface did
      # not error, it fabricated — so lowering the global default cannot reach
      # here. `nil` means nothing is set and the CLI decides, as it always has.
      agent: ModelPolicy.backend_for(:order_submit),
      model: ModelPolicy.for_surface(:order_submit),
      permission_mode: "dontAsk",
      timeout_ms: @submit_timeout_ms,
      login: true
    ]

    case agent_runner().(submit_prompt(order), opts) do
      {:ok, %{exit_status: 0, output: output}} -> verdict(output)
      {:ok, %{exit_status: _status}} -> {:error, :unknown}
      {:error, _reason} -> {:error, :unknown}
    end
  end

  # Test seam: `:trading_submit_runner` app env. The `:trading_order_submitter`
  # seam above replaces `run_submit/1` entirely, so it can't show a test the opts
  # this function builds — the floor being one of them.
  defp agent_runner,
    do: Application.get_env(:buster_claw, :trading_submit_runner, &AgentRunner.run/2)

  @doc """
  Read a submit run's stream, distinguishing "never sent" from "outcome unknown".

  The distinction is the whole point. If the stream contains no
  `place_equity_order` tool call then nothing reached the broker, and saying so
  is both true and safe — the operator can retry. If the call WAS made but no
  verdict came back, the order may be live, and only then do we report the
  unknown that forbids a retry.

  Getting this backwards in either direction is expensive: a false "unknown"
  strands an order that was never placed, and a false "nothing sent" invites a
  second submission of an order that already exists.
  """
  def verdict(output) when is_binary(output) do
    events =
      output
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case StreamEvent.parse(:claude, line) do
          {:ok, event} -> [event]
          :error -> []
        end
      end)

    if Enum.any?(events, &place_call?/1) do
      case Enum.filter(events, &(&1.kind == :result and is_binary(&1.text))) do
        [] -> {:error, :unknown}
        results -> results |> List.last() |> Map.fetch!(:text) |> parse_submit_result()
      end
    else
      {:error, :not_sent}
    end
  end

  defp place_call?(%StreamEvent{kind: :tool_use, tool: "mcp__robinhood__place_equity_order"}),
    do: true

  defp place_call?(_event), do: false

  @doc """
  Claude arguments for the submit run: the write tool, and nothing else.

  Same three-part confinement as `Trading.read_only_cli_args/0`, and for the
  reasons documented there — notably that `--tools ""` would take the MCP tools
  down with the built-ins, which on a submit run means an order that silently
  never happens.
  """
  def submit_cli_args do
    [
      "--disallowedTools",
      Enum.join(Trading.denied_tools(), ","),
      "--allowedTools",
      Enum.join(@submit_tools, ","),
      "--strict-mcp-config",
      "--mcp-config",
      Trading.ensure_mcp_config()
    ]
  end

  @doc "The submit prompt. Every parameter is a literal from the struct."
  def submit_prompt(%__MODULE__{} = order) do
    """
    Place exactly ONE equity order. Do not modify any parameter below, do not
    substitute a different symbol or size, and do not place a second order for
    any reason — not even if the first appears to fail.

    1. Call mcp__robinhood__get_accounts and find the account whose number ENDS
       IN #{order.account_last4}. If none does, or more than one does, output
       {"error": "account not resolved"} and STOP without placing anything.
    2. Call mcp__robinhood__place_equity_order for that account_number with:
       side: #{order.side}
       symbol: #{order.symbol}
       #{size_line(order)}
       order type: #{order.order_type}#{limit_line(order)}
       time in force: #{order.time_in_force}

    Then output ONLY one JSON object — no prose, no code fences:
    {"order_id": "<the broker's order id>", "state": "<the broker's state>"}

    If the broker REFUSES the order, output exactly:
    {"error": "<the broker's one-line reason>"}

    If a tool call fails or times out, output exactly:
    {"error": "unknown — order status not confirmed"}
    Never retry a place_equity_order call.
    """
  end

  defp size_line(%{quantity: nil, amount_usd: amount}),
    do: "notional amount in dollars: #{trim_number(amount)}"

  defp size_line(%{quantity: qty}), do: "quantity in shares: #{trim_number(qty)}"

  # Three spaces to sit under the sibling parameter lines: the heredoc above is
  # dedented by its closing delimiter, this string is not.
  defp limit_line(%{order_type: "limit", limit_price: price}),
    do: "\n   limit price: #{trim_number(price)}"

  defp limit_line(_order), do: ""

  @doc "Read the submit run's verdict. Exposed for tests."
  def parse_submit_result(output) when is_binary(output) do
    with [json] <- Regex.run(~r/\{.*\}/s, output) || :nomatch,
         {:ok, decoded} <- Jason.decode(json) do
      case decoded do
        %{"order_id" => id} when is_binary(id) and id != "" -> {:ok, id}
        %{"error" => reason} -> refusal(to_string(reason))
        _other -> {:error, :unknown}
      end
    else
      _error -> {:error, :unknown}
    end
  end

  # "unknown" from the model means the tool call itself did not resolve, which is
  # the one case that must NOT read as a clean refusal — the order may be live.
  defp refusal("unknown" <> _rest), do: {:error, :unknown}
  defp refusal(reason), do: {:error, {:refused, reason}}
end
