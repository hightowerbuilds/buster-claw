defmodule BusterClawWeb.TerminalTokenTest do
  @moduledoc """
  Clinch finding #7: the in-app terminal gets its own token.

  ## What was wrong

  `RequireTrusted`'s reasoning for why the full token is safe is that it lives in
  the Keychain and the shell's process environment, and an attacker **"gets no
  shell and therefore no Keychain"**.

  The in-app terminal *is* a shell, and it inherited the full token. So an agent
  running there — which is the ordinary way this product is used — had exactly the
  capability that argument says is out of reach: it could store, delete and rotate
  credentials. The Clinch's founding rule is *use, never manage*, and it was
  untrue wherever an agent had a prompt.

  ## The shape of the fix, and what these tests defend

  A fourth token, trusted-equivalent for **commands** and refused for
  **management**. Both halves need guarding, and the second is the one that will
  quietly rot: a change that made the terminal token merely "less powerful" would
  break the dispatch loop this product runs on, and the tests below are what says
  so out loud.
  """
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.ApiToken
  alias BusterClaw.PolicyEngine

  defp as(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  describe "the terminal token is its own token" do
    test "it is distinct from every other token" do
      tokens = [
        ApiToken.value(),
        ApiToken.terminal_value(),
        ApiToken.agent_value(),
        ApiToken.mcp_value()
      ]

      assert length(Enum.uniq(tokens)) == 4,
             "the terminal token must be distinct — sharing bytes with the full " <>
               "token is the bug, not the fix"
    end

    test "it authenticates as :terminal", %{conn: conn} do
      # An AUTHENTICATED route — /api/commands is deliberately open, so it assigns
      # no caller and would prove nothing here.
      conn =
        conn
        |> as(ApiToken.terminal_value())
        |> post(~p"/api/run", %{"command" => "document_list", "args" => %{}})

      assert conn.status == 200
      assert conn.assigns.caller == :terminal
    end
  end

  describe "management is refused — the point of the change" do
    test "it cannot store a credential", %{conn: conn} do
      conn =
        conn
        |> as(ApiToken.terminal_value())
        |> post(~p"/api/clinch", %{"kind" => "sign_in", "name" => "x", "value" => "y"})

      assert conn.status == 403
    end

    test "it cannot delete a credential", %{conn: conn} do
      conn =
        conn
        |> as(ApiToken.terminal_value())
        |> delete(~p"/api/clinch", %{"kind" => "sign_in", "name" => "x"})

      assert conn.status == 403
    end

    test "it cannot rotate the master key", %{conn: conn} do
      conn =
        conn
        |> as(ApiToken.terminal_value())
        |> post(~p"/api/clinch/rotate", %{"new_key" => "some-new-key"})

      assert conn.status == 403
    end
  end

  describe "everything else still works — the half that must not regress" do
    # Scoping the terminal is only correct if the terminal can still do its job.
    # An agent in that shell works the Dispatch queue, sends mail, and deletes
    # things; a token that refused those would close the hole by breaking the
    # product.
    test "the terminal runs restricted and gated commands, exactly like trusted" do
      for command <- [
            %{name: "gmail_send", tier: :restricted, gated: true},
            %{name: "document_save", tier: :restricted, gated: false},
            %{name: "dispatch_claim", tier: :mutate, gated: false}
          ] do
        request = Map.put(command, :caller, :terminal)

        assert PolicyEngine.check(request) == :allow,
               "#{command.name} was refused for the terminal caller. The terminal " <>
                 "runs the operator's own agent — refusing gated commands there " <>
                 "breaks the dispatch loop this product is built on."
      end
    end

    test "a lesser caller is still refused the same commands" do
      # The positive control: if PolicyEngine allowed everything, the test above
      # would prove nothing about :terminal specifically.
      assert {:confirm, _} =
               PolicyEngine.check(%{
                 name: "gmail_send",
                 caller: :agent_untrusted,
                 tier: :restricted,
                 gated: true
               })

      assert {:confirm, _} =
               PolicyEngine.check(%{
                 name: "document_save",
                 caller: :mcp,
                 tier: :restricted,
                 gated: false
               })
    end

    test "it can run commands over the API", %{conn: conn} do
      conn =
        conn
        |> as(ApiToken.terminal_value())
        |> post(~p"/api/run", %{"command" => "document_list", "args" => %{}})

      assert %{"ok" => true} = json_response(conn, 200)
    end
  end
end
