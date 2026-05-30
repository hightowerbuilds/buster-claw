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
