defmodule BusterClaw.Provider.AnthropicAgenticTest do
  use BusterClaw.DataCase

  alias BusterClaw.Provider.Anthropic

  setup do
    {:ok, provider} =
      BusterClaw.Providers.create_provider(%{
        name: "anth-agent",
        type: "anthropic",
        model: "claude-sonnet-4-6",
        api_key: "test-key"
      })

    %{provider: provider}
  end

  test "runs a tool call and returns the model's final text", %{provider: provider} do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      response =
        if has_tool_result?(payload) do
          %{
            "stop_reason" => "end_turn",
            "content" => [%{"type" => "text", "text" => "Status looks healthy."}]
          }
        else
          # Confirm we sent the tools catalog
          assert is_list(payload["tools"])
          assert Enum.any?(payload["tools"], &(&1["name"] == "runtime_status"))

          %{
            "stop_reason" => "tool_use",
            "content" => [
              %{"type" => "text", "text" => "Let me check..."},
              %{
                "type" => "tool_use",
                "id" => "toolu_1",
                "name" => "runtime_status",
                "input" => %{}
              }
            ]
          }
        end

      Req.Test.json(conn, response)
    end)

    parent = self()

    assert :ok =
             Anthropic.chat_agentic(
               provider,
               [%{role: "user", content: "Are we healthy?"}],
               fn chunk -> send(parent, {:chunk, chunk}) end
             )

    assert_receive {:chunk, text}
    assert text =~ "healthy"
  end

  test "refuses to execute restricted-tier commands sent by the model", %{provider: provider} do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      response =
        if has_tool_result?(payload) do
          # Find the message containing tool_results (the most recent user message)
          tool_result_msg =
            Enum.find(payload["messages"], fn m ->
              m["role"] == "user" and is_list(m["content"]) and
                Enum.any?(m["content"], &(&1["type"] == "tool_result"))
            end)

          tool_results = Enum.filter(tool_result_msg["content"], &(&1["type"] == "tool_result"))
          assert Enum.any?(tool_results, &(&1["is_error"] == true))

          %{
            "stop_reason" => "end_turn",
            "content" => [%{"type" => "text", "text" => "Can't delete — refused."}]
          }
        else
          %{
            "stop_reason" => "tool_use",
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "toolu_x",
                "name" => "source_delete",
                "input" => %{"id" => 1}
              }
            ]
          }
        end

      Req.Test.json(conn, response)
    end)

    parent = self()

    assert :ok =
             Anthropic.chat_agentic(
               provider,
               [%{role: "user", content: "Delete source 1"}],
               fn chunk -> send(parent, {:chunk, chunk}) end
             )

    assert_receive {:chunk, _text}
  end

  defp has_tool_result?(payload) do
    payload["messages"]
    |> Enum.any?(fn msg ->
      content = msg["content"]
      is_list(content) and Enum.any?(content, &(&1["type"] == "tool_result"))
    end)
  end
end
