defmodule BusterClaw.BrowserControl.PageTargetingLiveTest do
  @moduledoc """
  Text targeting against a REAL browser, on the DOM shape that defeated it.

  The stub suite in `PageTest` can only assert the JS we generate; it cannot
  assert what the JS *does*. That gap is exactly how the 07-25 field-test defect
  survived — so the regression for it belongs here, where the page is real and
  the resolution actually runs.

  Reproduces the Amazon product page precisely: a customer review's variant
  byline ("Size: 45 inchesColor: Dark Brown") appearing EARLIER in DOM order
  than the real size swatch ("45 inches"). Under the old `.find(includes)` the
  review link won, the run navigated to the reviews page, and it was one unlucky
  DOM order away from silently carting a 54" lace.

  Excluded by default; run with `mix test --include browser_engine` on a machine
  with a Chromium-family browser.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.{Page, Pool, Session}

  @moduletag :browser_engine
  @moduletag timeout: 90_000

  # Base64 rather than percent-encoding: `URI.encode/1` does not escape `#`, so
  # a `data:text/html,` URL truncates at the first one and the page silently
  # arrives half-built. These fixtures happen not to contain `#` today, which is
  # exactly what makes it a trap for the next one.
  defp page(session, body) do
    html = "<html><body>#{body}</body></html>"
    :ok = Session.navigate(session, "data:text/html;base64," <> Base.encode64(html))
    session
  end

  setup do
    {:ok, pool} = Pool.start_link(name: nil, max_sessions: 1, idle_ms: 60_000)
    {:ok, session} = Pool.checkout(pool)
    on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
    %{session: session}
  end

  test "the exact swatch wins over an earlier review byline that contains it", %{
    session: session
  } do
    session
    |> page("""
    <a href="/reviews" id="review">Size: 45 inchesColor: Dark Brown</a>
    <button id="swatch">45 inches</button>
    """)

    # The exact tier has exactly one member, so this resolves rather than
    # refusing — the ordinary case must keep working, not merely fail safely.
    # The returned label is the discriminator: the review link's label is the
    # full byline, so "45 inches" can only have come from the swatch.
    assert {:ok, %{"clicked" => "45 inches"}} = Page.click(session, %{"text" => "45 inches"})
  end

  test "genuinely ambiguous text refuses instead of picking the first", %{session: session} do
    session
    |> page("""
    <button>Add to cart</button>
    <button>Add to cart</button>
    """)

    assert {:error, {:ambiguous_text, 2}} = Page.click(session, %{"text" => "Add to cart"})
  end

  test "substring still resolves when nothing matches exactly", %{session: session} do
    session |> page(~s|<button>Proceed to checkout now</button>|)

    assert {:ok, %{"clicked" => "Proceed to checkout now"}} =
             Page.click(session, %{"text" => "Proceed to checkout"})
  end

  test "ambiguity within the substring tier also refuses", %{session: session} do
    session
    |> page("""
    <a href="/a">45 inches, Black</a>
    <a href="/b">45 inches, Brown</a>
    """)

    assert {:error, {:ambiguous_text, 2}} = Page.click(session, %{"text" => "45 inches"})
  end

  test "a selector still takes the first of several — text is the strict one", %{
    session: session
  } do
    session
    |> page("""
    <button class="opt">first</button>
    <button class="opt">second</button>
    """)

    assert {:ok, %{"clicked" => "first"}} = Page.click(session, %{"selector" => ".opt"})
  end

  test "fill refuses on ambiguous text rather than typing into a guess", %{session: session} do
    session
    |> page("""
    <input placeholder="Search" value="query">
    <input placeholder="Search" value="query">
    """)

    assert {:error, {:ambiguous_text, 2}} = Page.fill(session, %{"text" => "query"}, "laces")
  end
end
