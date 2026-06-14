defmodule BusterClaw.ManualTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Manual

  test "html renders the user-guide sections into one document" do
    html = Manual.html()
    assert html =~ "<title>Buster Claw — Manual</title>"
    assert html =~ "Introduction"
    # Section anchors for the table-of-contents links.
    assert html =~ ~s(id="introduction")
  end
end
