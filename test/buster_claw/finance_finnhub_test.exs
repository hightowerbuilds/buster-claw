defmodule BusterClaw.FinanceFinnhubTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Finance.Finnhub

  @stub BusterClaw.FinnhubHTTP
  @opts [req_options: [plug: {Req.Test, BusterClaw.FinnhubHTTP}]]

  setup do
    Req.Test.verify_on_exit!()
    prev = Application.get_env(:buster_claw, :finnhub_api_key)
    on_exit(fn -> Application.put_env(:buster_claw, :finnhub_api_key, prev) end)
    :ok
  end

  defp with_key(key \\ "test-key"), do: Application.put_env(:buster_claw, :finnhub_api_key, key)

  test "quote returns price fields with source + as-of when a key is configured" do
    with_key()

    Req.Test.stub(@stub, fn conn ->
      assert conn.request_path == "/api/v1/quote"

      Req.Test.json(conn, %{
        "c" => 150.25,
        "d" => 1.5,
        "dp" => 1.01,
        "h" => 151.0,
        "l" => 148.0,
        "o" => 149.0,
        "pc" => 148.75,
        "t" => 1_700_000_000
      })
    end)

    assert {:ok, result} = Finnhub.quote("aapl", @opts)
    assert result.symbol == "AAPL"
    assert result.source == "Finnhub"
    assert result.price == 150.25
    assert result.previous_close == 148.75
    # `t` (unix) becomes the as-of timestamp.
    assert result.as_of == "2023-11-14T22:13:20Z"
    assert result.note =~ "delayed"
  end

  test "news returns articles each carrying its own as-of" do
    with_key()

    Req.Test.stub(@stub, fn conn ->
      assert conn.request_path == "/api/v1/company-news"

      Req.Test.json(conn, [
        %{
          "headline" => "Apple ships thing",
          "summary" => "...",
          "url" => "https://example.com/a",
          "source" => "Reuters",
          "datetime" => 1_700_000_000
        },
        %{
          "headline" => "Apple does other thing",
          "summary" => "...",
          "url" => "https://example.com/b",
          "source" => "Bloomberg",
          "datetime" => 1_700_086_400
        }
      ])
    end)

    assert {:ok, result} = Finnhub.news("AAPL", @opts)
    assert result.source == "Finnhub"
    assert [first, second] = result.articles
    assert first.headline == "Apple ships thing"
    assert first.source == "Reuters"
    assert first.as_of == "2023-11-14T22:13:20Z"
    assert second.url == "https://example.com/b"
  end

  test "without a configured key, calls return :not_configured (no tokenless request)" do
    Application.put_env(:buster_claw, :finnhub_api_key, nil)

    # No Req.Test.stub installed: if a request were made, it would fail loudly.
    assert {:error, :not_configured} = Finnhub.quote("AAPL", @opts)
    assert {:error, :not_configured} = Finnhub.news("AAPL", @opts)
  end
end
