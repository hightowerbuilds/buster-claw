defmodule BusterClaw.URLGuardTest do
  # Async-safe: resolve_dns is disabled in test config, so no network is touched.
  use ExUnit.Case, async: true

  alias BusterClaw.URLGuard

  describe "validate/1 blocks internal targets" do
    test "loopback and metadata IPv4 literals" do
      assert {:error, :blocked_host} = URLGuard.validate("http://127.0.0.1/")
      assert {:error, :blocked_host} = URLGuard.validate("http://127.5.5.5:9000/x")

      assert {:error, :blocked_host} =
               URLGuard.validate("http://169.254.169.254/latest/meta-data")

      assert {:error, :blocked_host} = URLGuard.validate("http://0.0.0.0/")
    end

    test "private RFC1918 ranges" do
      assert {:error, :blocked_host} = URLGuard.validate("http://10.0.0.1/")
      assert {:error, :blocked_host} = URLGuard.validate("http://172.16.0.1/")
      assert {:error, :blocked_host} = URLGuard.validate("http://172.31.255.255/")
      assert {:error, :blocked_host} = URLGuard.validate("http://192.168.1.1/")
    end

    test "loopback hostnames" do
      assert {:error, :blocked_host} = URLGuard.validate("http://localhost:4000/")
      assert {:error, :blocked_host} = URLGuard.validate("http://api.localhost/")
      assert {:error, :blocked_host} = URLGuard.validate("http://printer.local/")
    end

    test "IPv6 loopback / link-local / unique-local literals" do
      assert {:error, :blocked_host} = URLGuard.validate("http://[::1]/")
      assert {:error, :blocked_host} = URLGuard.validate("http://[fe80::1]/")
      assert {:error, :blocked_host} = URLGuard.validate("http://[fc00::1]/")
      # IPv4-mapped loopback
      assert {:error, :blocked_host} = URLGuard.validate("http://[::ffff:127.0.0.1]/")
    end

    test "non-http schemes" do
      assert {:error, :blocked_scheme} = URLGuard.validate("file:///etc/passwd")
      assert {:error, :blocked_scheme} = URLGuard.validate("ftp://example.com/x")
      assert {:error, :blocked_scheme} = URLGuard.validate("gopher://example.com/")
    end

    test "malformed input" do
      assert {:error, :blocked_scheme} = URLGuard.validate("not a url")
      assert {:error, :missing_host} = URLGuard.validate("http://")
      assert {:error, :invalid_url} = URLGuard.validate(nil)
    end
  end

  describe "validate/1 allows public targets" do
    test "public hostname (DNS resolution disabled in test)" do
      assert :ok = URLGuard.validate("https://example.com/article")
    end

    test "public IPv4 literal" do
      assert :ok = URLGuard.validate("https://8.8.8.8/")
    end
  end

  describe "validate/2 with DNS resolution (injected resolver)" do
    @describetag capture_log: true

    # Builds a resolver fun from a per-family answer map; unlisted families NXDOMAIN.
    defp resolver(answers) do
      fn _host, family -> Map.get(answers, family, {:error, :nxdomain}) end
    end

    defp validate_resolved(url, answers) do
      URLGuard.validate(url, resolve_dns: true, resolver: resolver(answers))
    end

    test "AAAA-only host resolving to IPv6 loopback is blocked" do
      assert {:error, :blocked_host} =
               validate_resolved("https://evil.example/", %{
                 inet6: {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
               })
    end

    test "AAAA-only host resolving to link-local / unique-local is blocked" do
      assert {:error, :blocked_host} =
               validate_resolved("https://evil.example/", %{
                 inet6: {:ok, [{0xFE80, 0, 0, 0, 0, 0, 0, 1}]}
               })

      assert {:error, :blocked_host} =
               validate_resolved("https://evil.example/", %{
                 inet6: {:ok, [{0xFC00, 0, 0, 0, 0, 0, 0, 1}]}
               })
    end

    test "AAAA-only host resolving to an IPv4-mapped internal address is blocked" do
      # ::ffff:127.0.0.1
      assert {:error, :blocked_host} =
               validate_resolved("https://evil.example/", %{
                 inet6: {:ok, [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}]}
               })
    end

    test "dual-stack host with one internal family is blocked" do
      # Public A record, but the AAAA answer points inside — any bad address blocks.
      assert {:error, :blocked_host} =
               validate_resolved("https://evil.example/", %{
                 inet: {:ok, [{93, 184, 216, 34}]},
                 inet6: {:ok, [{0xFC00, 0, 0, 0, 0, 0, 0, 1}]}
               })

      # And the mirror: public AAAA, private A.
      assert {:error, :blocked_host} =
               validate_resolved("https://evil.example/", %{
                 inet: {:ok, [{10, 0, 0, 5}]},
                 inet6: {:ok, [{0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]}
               })
    end

    test "host resolving to nothing in either family fails closed" do
      assert {:error, :unresolvable_host} = validate_resolved("https://ghost.example/", %{})
    end

    test "clean public host resolves and passes" do
      assert :ok =
               validate_resolved("https://example.com/", %{
                 inet: {:ok, [{93, 184, 216, 34}]},
                 inet6: {:ok, [{0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]}
               })
    end

    test "AAAA-only public host passes" do
      assert :ok =
               validate_resolved("https://v6only.example/", %{
                 inet6: {:ok, [{0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]}
               })
    end

    test "IP literals skip resolution entirely" do
      # A resolver that would explode if called — literals must never reach it.
      exploding = fn _host, _family -> raise "resolver must not be called for literals" end

      assert :ok =
               URLGuard.validate("https://8.8.8.8/", resolve_dns: true, resolver: exploding)

      assert {:error, :blocked_host} =
               URLGuard.validate("http://[::1]/", resolve_dns: true, resolver: exploding)
    end
  end

  describe "req_step/1" do
    test "passes a safe request through unchanged" do
      request = Req.new(url: "https://example.com")
      assert URLGuard.req_step(request) == request
    end

    test "halts a blocked request with a synthetic 403" do
      request = Req.new(url: "http://169.254.169.254/")
      halted = URLGuard.req_step(request)
      assert {_req, %Req.Response{status: 403, body: body}} = halted
      assert body =~ "SSRF"
    end
  end
end
