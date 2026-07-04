defmodule BusterClaw.Humo.ExpressionTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Humo.Expression

  test "strips a style block and returns its decoded data" do
    text = "Here is the answer.\n\n```humo-style {\"energy\":0.9,\"temp\":\"warm\"}```"
    {clean, [expr]} = Expression.extract(text)

    assert clean == "Here is the answer."
    assert expr.type == "style"
    assert expr.data == %{"energy" => 0.9, "temp" => "warm"}
  end

  test "handles multiple blocks of different types in document order" do
    text = "```humo-style {\"mode\":\"gameboy\"}``` mid ```humo-graph {\"n\":1}```"
    {clean, exprs} = Expression.extract(text)

    assert clean == "mid"
    assert Enum.map(exprs, & &1.type) == ["style", "graph"]
  end

  test "drops malformed json as an expression but still strips the block (fail closed)" do
    text = "keep ```humo-style {not json}``` this"
    {clean, exprs} = Expression.extract(text)

    assert exprs == []
    refute clean =~ "humo-style"
    assert clean =~ "keep"
    assert clean =~ "this"
  end

  test "text with no block is returned unchanged" do
    {clean, exprs} = Expression.extract("just words")

    assert clean == "just words"
    assert exprs == []
  end

  test "parses a draw block with nested JSON (shapes list)" do
    text = ~s(Look:\n```humo-draw {"shapes":[{"kind":"circle","r":0.5},{"kind":"box"}]}```)
    {clean, [expr]} = Expression.extract(text)

    assert clean == "Look:"
    assert expr.type == "draw"
    assert %{"shapes" => [%{"kind" => "circle"}, %{"kind" => "box"}]} = expr.data
  end
end
