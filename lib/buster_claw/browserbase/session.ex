defmodule BusterClaw.Browserbase.Session do
  @moduledoc """
  Facade the `web_*` commands call — the single place with cloud-browser
  knowledge. Translates the string-keyed command contract into
  `SessionManager` (lifecycle) + `SessionClient` (driving) calls, and owns the
  business rules that must not live in the thin command bodies: the SSRF/URL
  guard on navigation, the 200 KB read cap, the non-submit click guard, and
  secret-shape flagging.

  The commands stay thin: unwrap args → call one function here → emit one
  Sentinel event → shape the result. This module never talks to the sidecar
  HTTP directly (that's `SessionClient`) and never bills (that's the
  `SessionManager` + `Browserbase` client).
  """

  alias BusterClaw.Browser.SessionClient
  alias BusterClaw.Browserbase
  alias BusterClaw.Browserbase.SessionManager
  alias BusterClaw.Ingest.Content
  alias BusterClaw.URLGuard

  @read_cap 200_000

  # Defense-in-depth only: a substring heuristic on the selector to refuse
  # obvious pay/submit affordances in Phase 2. Phase 4's confirmation gate is the
  # real safety net — this list is deliberately the same one that gate will lift.
  @submit_terms ~w(pay buy purchase checkout place-order place_order placeorder
                   order-now buy-now pay-now submit confirm subscribe donate payment)

  @secret_terms ~w(password card cc cvv cvc pan iban routing ssn secret)

  @doc "Open a driven cloud session; optionally navigate to a starting URL."
  def open(args \\ %{}) do
    with :ok <- ensure_available(),
         {:ok, handle} <- SessionManager.open() do
      base = %{session_id: handle.session_id, live_view_url: handle.live_view_url, status: "open"}
      maybe_navigate(base, handle.session_id, Map.get(args, "url"))
    end
  end

  defp maybe_navigate(base, session_id, url) when is_binary(url) and url != "" do
    case navigate(session_id, url) do
      {:ok, nav} -> {:ok, Map.put(base, :url, nav.url)}
      error -> error
    end
  end

  defp maybe_navigate(base, _session_id, _url), do: {:ok, base}

  def close(session_id) do
    with :ok <- ensure_available() do
      SessionManager.close(session_id)
      {:ok, %{closed: session_id}}
    end
  end

  def list do
    with :ok <- ensure_available() do
      sessions =
        Enum.map(SessionManager.list(), fn s ->
          %{
            session_id: s.id,
            live_view_url: s.live_view_url,
            opened_at: s.opened_at,
            last_used_at: s.last_used_at
          }
        end)

      {:ok, %{sessions: sessions, count: length(sessions)}}
    end
  end

  def navigate(session_id, url) do
    with :ok <- URLGuard.validate(url),
         {:ok, body} <- drive(session_id, &SessionClient.navigate(&1, url)) do
      {:ok, %{session_id: session_id, url: body["url"] || url, title: body["title"]}}
    end
  end

  def read(session_id) do
    with {:ok, body} <- drive(session_id, &SessionClient.read/1) do
      title = body["title"]
      html = (body["html"] || "") |> String.slice(0, @read_cap)

      {:ok,
       %{
         session_id: session_id,
         url: body["url"],
         title: title,
         markdown: Content.html_to_markdown(html, title)
       }}
    end
  end

  def find_elements(session_id, query) do
    with {:ok, body} <- drive(session_id, &SessionClient.find_elements(&1, query)) do
      elements = body["elements"] || []
      {:ok, %{session_id: session_id, elements: elements, count: length(elements)}}
    end
  end

  def fill(session_id, selector, value) do
    with {:ok, _body} <- drive(session_id, &SessionClient.fill(&1, selector, value)) do
      {:ok,
       %{
         session_id: session_id,
         selector: selector,
         value_length: String.length(value),
         redacted: secret_shaped?(selector, value)
       }}
    end
  end

  def select(session_id, selector, value) do
    with {:ok, _body} <- drive(session_id, &SessionClient.select(&1, selector, value)) do
      {:ok, %{session_id: session_id, selector: selector, selected: value}}
    end
  end

  @doc "Click a selector — refused in Phase 2 if it looks like a submit/pay affordance."
  def click(session_id, selector) do
    if submit_affordance?(selector) do
      {:error, {:submit_affordance_refused, selector}}
    else
      with {:ok, body} <- drive(session_id, &SessionClient.click(&1, selector)) do
        {:ok,
         %{session_id: session_id, clicked: selector, url: body["url"], title: body["title"]}}
      end
    end
  end

  @doc "Screenshot the live cloud page; returns the raw PNG bytes for the caller to persist."
  def screenshot(session_id) do
    with {:ok, body} <- drive(session_id, &SessionClient.screenshot/1),
         b64 when is_binary(b64) <- body["base64"],
         {:ok, png} <- Base.decode64(b64) do
      {:ok, %{session_id: session_id, png: png, bytes: byte_size(png)}}
    else
      nil -> {:error, :bad_screenshot}
      :error -> {:error, :bad_screenshot}
      other -> other
    end
  end

  def extract(session_id, spec) do
    with {:ok, body} <- drive(session_id, &SessionClient.extract(&1, spec)) do
      data = body["data"]
      {:ok, %{session_id: session_id, data: data, count: count_of(data)}}
    end
  end

  @doc false
  def submit_affordance?(selector) do
    s = selector |> to_string() |> String.downcase()
    Enum.any?(@submit_terms, &String.contains?(s, &1))
  end

  # --- internals ---

  # Resolve the session to its sidecar id (deferring the idle clock) and run the
  # driver call. An unknown/expired id short-circuits with :unknown_session.
  defp drive(session_id, fun) do
    with :ok <- ensure_available(),
         {:ok, sidecar_id} <- SessionManager.checkout(session_id) do
      fun.(sidecar_id)
    end
  end

  defp ensure_available do
    cond do
      not Browserbase.enabled?() -> {:error, :not_configured}
      is_nil(Process.whereis(SessionManager)) -> {:error, :browserbase_unavailable}
      true -> :ok
    end
  end

  defp secret_shaped?(selector, value) do
    sel = selector |> to_string() |> String.downcase()
    Enum.any?(@secret_terms, &String.contains?(sel, &1)) or luhn_card?(value)
  end

  # A 13–19 digit run that passes Luhn — a payment-card shape worth flagging.
  defp luhn_card?(value) when is_binary(value) do
    digits = String.replace(value, ~r/[\s-]/, "")
    digits =~ ~r/^\d{13,19}$/ and luhn_valid?(digits)
  end

  defp luhn_card?(_), do: false

  defp luhn_valid?(digits) do
    sum =
      digits
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + luhn_digit(String.to_integer(d), i) end)

    rem(sum, 10) == 0
  end

  defp luhn_digit(n, i) do
    doubled = if rem(i, 2) == 1, do: n * 2, else: n
    if doubled > 9, do: doubled - 9, else: doubled
  end

  defp count_of(data) when is_list(data), do: length(data)
  defp count_of(_), do: 1
end
