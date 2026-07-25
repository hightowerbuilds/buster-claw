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
