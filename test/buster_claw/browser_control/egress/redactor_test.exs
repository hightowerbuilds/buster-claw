defmodule BusterClaw.BrowserControl.Egress.RedactorTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Egress.Redactor

  test "a Luhn-valid card becomes the typed card placeholder and is counted" do
    {red, counts} = Redactor.redact("pay with 4242 4242 4242 4242 today")
    assert red == "pay with ⟨redacted:card⟩ today"
    assert counts.card == 1
  end

  test "a non-Luhn digit run is left alone (not every long number is a card)" do
    {red, counts} = Redactor.redact("order 1234 5678 9012 3456 confirmed")
    assert red =~ "1234 5678 9012 3456"
    assert counts.card == 0
  end

  test "SSN shapes are redacted" do
    {red, counts} = Redactor.redact("ssn 123-45-6789 on file")
    assert red == "ssn ⟨redacted:ssn⟩ on file"
    assert counts.ssn == 1
  end

  test "IBANs are redacted" do
    {red, counts} = Redactor.redact("send to GB82WEST12345698765432 please")
    assert red =~ "⟨redacted:iban⟩"
    assert counts.iban == 1
  end

  test "credential-prefixed tokens are redacted before card scanning claims their digits" do
    {red, counts} = Redactor.redact("Authorization: Bearer sk-live-abc123DEF456ghi789")
    assert red =~ "⟨redacted:token⟩"
    assert counts.token >= 1
    assert counts.card == 0
  end

  test "ordinary prose is untouched and counts stay zero" do
    text = "The printer paper is $12.99 and ships tomorrow to the office."
    assert {^text, counts} = Redactor.redact(text)
    assert counts == Redactor.zero_counts()
  end

  test "multiple secrets of one type are each counted" do
    {red, counts} = Redactor.redact("cards 4242424242424242 and 4111111111111111")
    assert counts.card == 2
    refute red =~ "4242"
    refute red =~ "4111"
  end

  test "non-binary input is a no-op with zero counts" do
    assert {nil, counts} = Redactor.redact(nil)
    assert counts == Redactor.zero_counts()
  end
end
