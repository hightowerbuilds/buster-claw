defmodule BusterClaw.URLGuard do
  @moduledoc """
  Guards outbound fetches against SSRF.

  Agent-supplied URLs (via `browser_fetch`, `source_ingest`, etc.) must not be
  able to reach the loopback interface, link-local/cloud-metadata addresses
  (169.254.0.0/16, incl. 169.254.169.254), or private RFC1918 ranges — otherwise
  a prompt-injected document could pivot to the app's own endpoints, the
  Playwright sidecar, or internal services.

  `validate/1` checks the scheme, blocks obvious internal hostnames and IP
  literals, and — when DNS resolution is enabled (config `:ssrf_resolve_dns`,
  default true; disabled in test) — resolves the host over **both** IPv4 and
  IPv6 and rejects it if *any* resolved address is in a blocked range. A host
  that resolves to nothing is refused (fail closed): a name we can't vet is a
  name we don't fetch. `req_step/1` applies the same check to every request
  hop, so redirects are re-validated.

  Residual gap: DNS-rebinding (TOCTOU between resolution and connect) is not
  addressed here — see docs/LOCAL_TRUST.md "Known accepted risks". Note that
  `req_step/1` re-validates per hop, so the practical rebinding window is a
  single request.
  """

  require Logger

  @blocked_hostnames ~w(localhost)

  @doc """
  Returns `:ok` if `url` is safe to fetch, or `{:error, reason}`.

  Options (used by tests; production callers rely on config defaults):

  - `:resolve_dns` — override config `:ssrf_resolve_dns`
  - `:resolver` — a `(charlist, :inet | :inet6) -> {:ok, [addr]} | {:error, term}`
    fun standing in for `:inet.getaddrs/2`
  """
  def validate(url, opts \\ [])

  def validate(url, opts) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri),
         {:ok, host} <- fetch_host(uri),
         :ok <- check_hostname(host) do
      check_resolved(host, opts)
    end
  end

  def validate(_url, _opts), do: {:error, :invalid_url}

  @doc """
  Req request step that re-validates the URL of every hop (including redirects).
  On a blocked URL it short-circuits with a synthetic 403 so callers see a
  normal bad-status error rather than reaching the host.
  """
  def req_step(request) do
    case validate(URI.to_string(request.url)) do
      :ok ->
        request

      {:error, reason} ->
        # A request step that returns {request, response} short-circuits the
        # pipeline — the host is never contacted.
        {request, %Req.Response{status: 403, body: "blocked by SSRF guard: #{inspect(reason)}"}}
    end
  end

  defp check_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp check_scheme(_uri), do: {:error, :blocked_scheme}

  defp fetch_host(%URI{host: host}) when is_binary(host) and host != "", do: {:ok, host}
  defp fetch_host(_uri), do: {:error, :missing_host}

  defp check_hostname(host) do
    normalized = String.downcase(host)

    cond do
      normalized in @blocked_hostnames -> {:error, :blocked_host}
      String.ends_with?(normalized, ".localhost") -> {:error, :blocked_host}
      String.ends_with?(normalized, ".local") -> {:error, :blocked_host}
      true -> check_literal_ip(host)
    end
  end

  defp check_literal_ip(host) do
    case parse_ip(host) do
      {:ok, addr} -> if blocked_ip?(addr), do: {:error, :blocked_host}, else: :ok
      :not_ip -> :ok
    end
  end

  defp check_resolved(host, opts) do
    cond do
      not resolve_dns?(opts) -> :ok
      match?({:ok, _}, parse_ip(host)) -> :ok
      true -> resolve_and_check(host, opts)
    end
  end

  # Resolve BOTH address families and vet every answer — an AAAA-only host must
  # not slip past the IPv6 blocklist just because the A lookup failed. A host
  # with no answers in either family fails CLOSED: it can't be fetched anyway,
  # and refusing removes the "unresolvable at check time, resolvable at connect
  # time" escape hatch.
  defp resolve_and_check(host, opts) do
    resolver = Keyword.get(opts, :resolver, &:inet.getaddrs/2)
    charlist = String.to_charlist(host)

    addrs =
      Enum.flat_map([:inet, :inet6], fn family ->
        case resolver.(charlist, family) do
          {:ok, addrs} -> addrs
          {:error, _reason} -> []
        end
      end)

    cond do
      addrs == [] ->
        Logger.warning("URLGuard: refusing unresolvable host #{host}")
        {:error, :unresolvable_host}

      Enum.any?(addrs, &blocked_ip?/1) ->
        Logger.warning("URLGuard: blocked host #{host} (resolves to an internal address)")
        {:error, :blocked_host}

      true ->
        :ok
    end
  end

  defp parse_ip(host) do
    # URLs may bracket IPv6 literals: http://[::1]/
    trimmed = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(trimmed)) do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> :not_ip
    end
  end

  # IPv4
  defp blocked_ip?({0, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b in 16..31, do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  defp blocked_ip?({100, b, _, _}) when b in 64..127, do: true
  defp blocked_ip?({a, _, _, _}) when a in 224..255, do: true
  # IPv6 loopback / unspecified
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped (::ffff:a.b.c.d) — unwrap and re-check the embedded IPv4
  defp blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    blocked_ip?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  # IPv6 link-local (fe80::/10) and unique-local (fc00::/7)
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp blocked_ip?(_addr), do: false

  defp resolve_dns?(opts) do
    Keyword.get(opts, :resolve_dns, Application.get_env(:buster_claw, :ssrf_resolve_dns, true))
  end
end
