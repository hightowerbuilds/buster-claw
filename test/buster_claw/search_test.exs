defmodule BusterClaw.SearchTest do
  use BusterClaw.DataCase

  alias BusterClaw.Search

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "parses DuckDuckGo HTML results" do
    body = """
    <div class="result">
      <a class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.com%2Fone&amp;rut=abc">Example &amp; Result</a>
      <a class="result__snippet">A useful result snippet.</a>
    </div>
    """

    assert [
             %Search.Result{
               title: "Example & Result",
               url: "https://example.com/one",
               snippet: "A useful result snippet."
             }
           ] = Search.parse_results(body)
  end

  test "fetches and formats bounded results" do
    Req.Test.stub(BusterClaw.SearchHTTP, fn conn ->
      Req.Test.html(conn, """
      <div class="result">
        <a class="result__a" href="https://example.com">Example</a>
        <div class="result__snippet">Snippet</div>
      </div>
      """)
    end)

    assert {:ok, results} =
             Search.search("elixir", req_options: [plug: {Req.Test, BusterClaw.SearchHTTP}])

    assert Search.format_results(results) =~ "1. Example"
    assert Search.format_results(results) =~ "https://example.com"
  end
end
