defmodule BusterClaw.Notes.LinksTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notes.Links

  describe "parse/1" do
    test "reads bare targets, folder paths, and aliases" do
      body = "See [[Remote access]], [[Projects/Launch|the plan]], and [[Ghost]]."

      assert Links.parse(body) == [
               %{target: "Remote access", label: nil},
               %{target: "Projects/Launch", label: "the plan"},
               %{target: "Ghost", label: nil}
             ]
    end

    test "a label may contain pipes without truncating the user's text" do
      assert [%{target: "Note", label: "a | b"}] = Links.parse("[[Note|a | b]]")
    end

    test "fenced blocks and inline code are not link syntax" do
      body = """
      Real: [[Remote access]]

      ```
      [[Fenced]]
      ```

      Inline `[[Spanned]]` stays code.

      ~~~markdown
      [[Tilde fenced]]
      ~~~
      """

      assert Links.parse(body) == [%{target: "Remote access", label: nil}]
    end

    test "a longer fence contains shorter runs without ending early" do
      body = """
      ````
      ```
      [[Inner]]
      ```
      ````

      [[Outer]]
      """

      assert Links.parse(body) == [%{target: "Outer", label: nil}]
    end

    test "an unterminated fence keeps the rest of the document as code" do
      # The user is mid-typing. Flickering their sample into links until they
      # close the fence would be the worst possible moment for it.
      assert Links.parse("```\n[[Still typing]]\n") == []
    end
  end
end
