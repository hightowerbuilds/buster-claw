defmodule BusterClaw.BrowserControl.PageTest do
  @moduledoc """
  The CDP page verbs against a scripted `Runtime.evaluate` surface — the JS is
  the contract under test: targeting (selector/text/index), the no-match shape,
  in-page exceptions as typed errors, and the wait poll loop's budget.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Page

  # The session IS the script: a fun from (method, params) to a CDP reply.
  defmodule StubSession do
    def command(script, method, params), do: script.(method, params)
  end

  defp opts, do: [session_mod: StubSession]

  defp evaluated(value) do
    fn "Runtime.evaluate", _params -> {:ok, %{"result" => %{"value" => value}}} end
  end

  test "current and read unwrap the evaluate envelope" do
    session = evaluated(%{"url" => "https://a.com/", "title" => "A"})
    assert {:ok, %{"url" => "https://a.com/", "title" => "A"}} = Page.current(session, opts())

    session =
      evaluated(%{"url" => "https://a.com/", "title" => "A", "text" => "hi", "links" => []})

    assert {:ok, %{"text" => "hi"}} = Page.read(session, opts())
  end

  # The 07-25 field test passed "input,form" and "#variation_size_name li" to
  # find_elements and got the same nav links both times: the option was accepted
  # and dropped.
  test "find_elements filters on selector, and indices still mean the whole page" do
    session = fn "Runtime.evaluate", %{"expression" => js} ->
      assert js =~ ~s|.filter(({el}) => el.matches("input,form"))|

      # The index is assigned from the FULL enumeration before filtering, so a
      # filtered row still carries the index `click index:` resolves against.
      assert js =~ ".map((el, index) => ({el: el, index: index}))"
      assert String.contains?(js, ".map((el, index)") and String.contains?(js, ".filter(({el})")

      index_at = :binary.match(js, ".map((el, index)") |> elem(0)
      filter_at = :binary.match(js, ".filter(({el})") |> elem(0)
      assert index_at < filter_at, "indices must be assigned before the selector filter"

      {:ok, %{"result" => %{"value" => [%{"index" => 7, "tag" => "input"}]}}}
    end

    assert {:ok, [%{"index" => 7}]} =
             Page.find_elements(session, [selector: "input,form"] ++ opts())
  end

  test "find_elements without a selector enumerates unfiltered" do
    session = fn "Runtime.evaluate", %{"expression" => js} ->
      refute js =~ "el.matches("
      {:ok, %{"result" => %{"value" => []}}}
    end

    assert {:ok, []} = Page.find_elements(session, opts())
    assert {:ok, []} = Page.find_elements(session, [selector: nil] ++ opts())
    assert {:ok, []} = Page.find_elements(session, [selector: ""] ++ opts())
  end

  test "a malformed selector surfaces as a typed js exception, like extract" do
    session = fn "Runtime.evaluate", _params ->
      {:ok, %{"exceptionDetails" => %{"text" => "not a valid selector"}}}
    end

    assert {:error, {:js_exception, "not a valid selector"}} =
             Page.find_elements(session, [selector: "!!"] ++ opts())
  end

  test "click by selector embeds the selector and strips the matched flag" do
    session = fn "Runtime.evaluate", %{"expression" => js} ->
      assert js =~ ~s|document.querySelector("#go")|
      {:ok, %{"result" => %{"value" => %{"matched" => true, "clicked" => "Go"}}}}
    end

    assert {:ok, %{"clicked" => "Go"}} = Page.click(session, %{"selector" => "#go"}, opts())
  end

  test "click by text and by index use the shared enumeration" do
    session = fn "Runtime.evaluate", %{"expression" => js} ->
      assert js =~ "querySelectorAll"
      {:ok, %{"result" => %{"value" => %{"matched" => true, "clicked" => "Buy"}}}}
    end

    assert {:ok, _} = Page.click(session, %{"text" => "Buy"}, opts())
    assert {:ok, _} = Page.click(session, %{"index" => 3}, opts())
    assert {:error, :missing_target} = Page.click(session, %{}, opts())
  end

  test "a no-match click/fill is a typed error, not a silent pass" do
    session = evaluated(%{"matched" => false})

    assert {:error, :no_match} = Page.click(session, %{"selector" => "#gone"}, opts())
    assert {:error, :no_match} = Page.fill(session, %{"selector" => "#gone"}, "x", opts())
  end

  describe "ambiguous text targeting (field test 07-25)" do
    test "several matches is a refusal, distinct from no-match" do
      session = evaluated(%{"matched" => false, "ambiguous" => 3})

      assert {:error, {:ambiguous_text, 3}} =
               Page.click(session, %{"text" => "45 inches"}, opts())

      assert {:error, {:ambiguous_text, 3}} =
               Page.fill(session, %{"text" => "45 inches"}, "x", opts())
    end

    test "the refusal carries a count and never the matched labels" do
      # Labels are page content; an error path is not egress-accounted, so the
      # count is all that may cross. Asserted here so a later "helpful" patch
      # that adds labels fails loudly instead of quietly widening egress.
      session = evaluated(%{"matched" => false, "ambiguous" => 2})
      assert {:error, {:ambiguous_text, 2}} = Page.click(session, %{"text" => "Buy"}, opts())
    end

    test "the generated JS resolves exact matches before substring matches" do
      session = fn "Runtime.evaluate", %{"expression" => js} ->
        assert js =~ ~s|label(el) === want|, "exact tier missing"
        assert js =~ ~s|label(el).includes(want)|, "substring tier missing"
        assert js =~ "exact.length > 0 ? exact :", "exact tier must be preferred"
        assert js =~ "pool.length > 1", "ambiguity check missing"
        {:ok, %{"result" => %{"value" => %{"matched" => true, "clicked" => "45 inches"}}}}
      end

      assert {:ok, _} = Page.click(session, %{"text" => "45 inches"}, opts())
    end

    test "selector and index keep first-match semantics — only text refuses" do
      session = evaluated(%{"matched" => true, "clicked" => "Go"})

      assert {:ok, _} = Page.click(session, %{"selector" => ".item"}, opts())
      assert {:ok, _} = Page.click(session, %{"index" => 0}, opts())
    end
  end

  test "fill JSON-encodes the value into the page script" do
    session = fn "Runtime.evaluate", %{"expression" => js} ->
      assert js =~ ~s("with \\"quotes\\"")
      {:ok, %{"result" => %{"value" => %{"matched" => true, "filled" => "input"}}}}
    end

    assert {:ok, %{"filled" => "input"}} =
             Page.fill(session, %{"selector" => "#q"}, ~s(with "quotes"), opts())
  end

  test "extract: whole page mirrors the tab shape; selector returns matches" do
    session = evaluated(%{"url" => "https://a.com/", "title" => "A", "text" => "body text"})
    assert {:ok, %{"text" => "body text", "title" => "A"}} = Page.extract(session, nil, opts())

    session = evaluated(%{"count" => 0, "matches" => []})
    assert {:ok, %{"count" => 0}} = Page.extract(session, "#missing", opts())
  end

  test "wait supports the tab vocabulary: ready and visible" do
    session = fn "Runtime.evaluate", %{"expression" => js} ->
      value =
        cond do
          js =~ "readyState" -> true
          js =~ "offsetParent" -> true
          true -> false
        end

      {:ok, %{"result" => %{"value" => value}}}
    end

    assert {:ok, %{matched: true}} = Page.wait(session, %{"ready" => true}, opts())
    assert {:ok, %{matched: true}} = Page.wait(session, %{"visible" => "#hero"}, opts())
  end

  test "wait polls until the condition holds and reports the waited time" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    session = fn "Runtime.evaluate", _params ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      {:ok, %{"result" => %{"value" => n >= 2}}}
    end

    assert {:ok, %{matched: true, waited_ms: 2}} =
             Page.wait(session, %{"selector" => "#late"}, opts() ++ [poll_ms: 1])
  end

  test "an expired wait budget is matched: false, not an error" do
    session = evaluated(false)

    assert {:ok, %{matched: false}} =
             Page.wait(session, %{"text" => "never"}, opts() ++ [timeout_ms: 3, poll_ms: 1])

    assert {:error, :missing_condition} = Page.wait(session, %{}, opts())
  end

  test "an in-page exception surfaces as a typed error" do
    session = fn "Runtime.evaluate", _params ->
      {:ok, %{"exceptionDetails" => %{"text" => "boom"}}}
    end

    assert {:error, {:js_exception, "boom"}} = Page.read(session, opts())
  end

  test "screenshot decodes the CDP payload" do
    session = fn "Page.captureScreenshot", %{} -> {:ok, %{"data" => Base.encode64("png")}} end
    assert {:ok, "png"} = Page.screenshot(session, opts())

    session = fn "Page.captureScreenshot", %{} -> {:ok, %{"data" => "!!!"}} end
    assert {:error, :bad_capture_data} = Page.screenshot(session, opts())
  end
end
