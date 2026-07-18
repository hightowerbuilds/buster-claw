defmodule BusterClaw.URLGuard do
  @moduledoc """
  Guards outbound fetches against SSRF.

  Agent-supplied URLs (via `browser_fetch`, `source_ingest`, etc.) must not be
  able to reach the loopback interface, link-local/cloud-metadata addresses
  (169.254.0.0/16, incl. 169.254.169.254), or private RFC1918 ranges — otherwise
  a prompt-injected document could pivot to the app's own endpoints or
  internal services.

  `validate/1` checks the scheme, blocks obvious internal hostnames and IP
  literals, and — when DNS resolution is enabled (config `:ssrf_resolve_dns`,
  default true; disabled in test) — resolves the host over **both** IPv4 and
  IPv6 and rejects it if *any* resolved address is in a blocked range. A host
  that resolves to nothing is refused (fail closed): a name we can't vet is a
  name we don't fetch.

  `attach/2` wires the guard into a `Req.Request`: every hop (including each
  redirect) is re-validated, and the connection is **pinned to the exact
  address that passed vetting**, closing the DNS-rebinding TOCTOU window — a
  rebinding nameserver can no longer answer public at check time and internal
  at connect time, because there is no second resolution. Pinning rewrites the
  hop's URL host to the vetted IP and hands the original hostname to the
  transport (`connect_options: [hostname: ...]`), which Mint uses for the Host
  header, TLS SNI, and certificate verification — on the wire the request is
  indistinguishable from an unpinned one; only the socket's destination is
  fixed. Residual gap: when resolution is disabled, or for the rare host with
  no vetted IPv4/IPv6 answer path, behavior falls back to validate-only.
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
  def validate(url, opts \\ []) do
    case vet(url, opts) do
      {:ok, _host, _addrs} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Attaches the SSRF guard to a `Req.Request`: appends the per-hop
  validate-and-pin request step and prepends the response step that restores
  the original URL before Req resolves a redirect `Location` against it.
  Options are the same as `validate/2`.
  """
  def attach(%Req.Request{} = request, opts \\ []) do
    request
    |> Req.Request.append_request_steps(ssrf_guard: &req_step(&1, opts))
    |> Req.Request.prepend_response_steps(ssrf_unpin: &unpin_step/1)
  end

  @doc """
  Req request step that validates the request URL and pins the connection to
  the vetted address. On a blocked URL it short-circuits with a synthetic 403
  so callers see a normal bad-status error rather than reaching the host.

  On its own this guards a single hop — use `attach/2`, whose response step
  re-arms this one so every redirect hop is re-validated and re-pinned.
  """
  def req_step(request, opts \\ []) do
    case vet(URI.to_string(request.url), opts) do
      {:ok, host, [_ | _] = addrs} ->
        pin(request, host, pick_address(addrs))

      {:ok, _host, _no_pin} ->
        request

      {:error, reason} ->
        # A request step that returns {request, response} short-circuits the
        # pipeline — the host is never contacted.
        {request, %Req.Response{status: 403, body: "blocked by SSRF guard: #{inspect(reason)}"}}
    end
  end

  # Runs on every hop's response, before Req's :redirect step. Two jobs:
  #
  # 1. Restore the pre-pin URL (and connect options), so a relative Location
  #    is resolved against the original hostname, not the pinned IP.
  # 2. Re-arm the guard. Req consumes `current_request_steps` as the pipeline
  #    runs, and the :redirect/:retry steps re-enter `run_request/1` WITHOUT
  #    resetting it — request steps do NOT re-run on subsequent hops on their
  #    own. Without this re-arm a redirect hop would be neither validated nor
  #    pinned (a public server could 302 straight to the metadata address).
  defp unpin_step({request, response}) do
    {request |> restore_pin() |> rearm_guard(), response}
  end

  defp restore_pin(request) do
    case Req.Request.get_private(request, :ssrf_pin) do
      %{url: url, connect_options: original} ->
        %{request | url: url}
        |> restore_connect_options(original)
        |> Req.Request.put_private(:ssrf_pin, nil)

      _ ->
        request
    end
  end

  defp rearm_guard(%{current_request_steps: steps} = request) do
    if :ssrf_guard in steps do
      request
    else
      %{request | current_request_steps: steps ++ [:ssrf_guard]}
    end
  end

  # Vets a URL and returns `{:ok, host, addrs}` where addrs is the vetted
  # address list (pinnable), or `[]` when there is nothing to pin (resolution
  # disabled, or the host is already an IP literal — the connection can only
  # go where the check looked).
  defp vet(url, opts) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri),
         {:ok, host} <- fetch_host(uri),
         :ok <- check_hostname(host) do
      cond do
        not resolve_dns?(opts) -> {:ok, host, []}
        match?({:ok, _}, parse_ip(host)) -> {:ok, host, []}
        true -> resolve_and_check(host, opts)
      end
    end
  end

  defp vet(_url, _opts), do: {:error, :invalid_url}

  # Prefer IPv4: pinning an IPv6 address additionally requires flipping the
  # transport to inet6, so only do that when the host is IPv6-only.
  defp pick_address(addrs) do
    Enum.find(addrs, &(tuple_size(&1) == 4)) || hd(addrs)
  end

  defp pin(request, host, addr) do
    saved = %{url: request.url, connect_options: request.options[:connect_options]}
    ip = addr |> :inet.ntoa() |> List.to_string()

    connect_options =
      (request.options[:connect_options] || [])
      |> Keyword.put(:hostname, host)
      |> maybe_inet6(addr)

    %{request | url: %{request.url | host: ip}}
    |> put_option(:connect_options, connect_options)
    |> Req.Request.put_private(:ssrf_pin, saved)
  end

  defp maybe_inet6(connect_options, addr) when tuple_size(addr) == 8 do
    Keyword.update(
      connect_options,
      :transport_opts,
      [inet6: true],
      &Keyword.put(&1, :inet6, true)
    )
  end

  defp maybe_inet6(connect_options, _addr), do: connect_options

  defp restore_connect_options(request, nil),
    do: %{request | options: Map.delete(request.options, :connect_options)}

  defp restore_connect_options(request, original),
    do: put_option(request, :connect_options, original)

  defp put_option(request, key, value),
    do: %{request | options: Map.put(request.options, key, value)}

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
        {:ok, host, addrs}
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
