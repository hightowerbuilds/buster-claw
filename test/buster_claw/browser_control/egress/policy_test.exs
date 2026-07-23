defmodule BusterClaw.BrowserControl.Egress.PolicyTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Egress.Policy

  test "an ordinary host defaults to :full" do
    assert Policy.level_for("shop.example.com") == :full
  end

  test "banking / health / government hosts default to :structure_only" do
    assert Policy.level_for("secure.chase.com") == :structure_only
    assert Policy.level_for("mychart.hospital.org") == :structure_only
    assert Policy.level_for("www.irs.gov") == :structure_only
  end

  test "sensitive?/1 flags the categories and clears ordinary hosts" do
    assert Policy.sensitive?("bank.example.com")
    refute Policy.sensitive?("example.com")
    # A bare fragment must match a label, not any substring — 'amex' shouldn't
    # fire on an unrelated word buried in a domain.
    refute Policy.sensitive?("teamexcellence.com")
  end

  test "an operator override wins over the default" do
    assert Policy.level_for("shop.example.com", overrides: [{"example.com", :never}]) == :never
    assert Policy.level_for("secure.chase.com", overrides: [{"chase.com", :full}]) == :full
  end

  test "the most specific override wins" do
    overrides = [{"example.com", :full}, {"pay.example.com", :never}]
    assert Policy.level_for("pay.example.com", overrides: overrides) == :never
    assert Policy.level_for("www.example.com", overrides: overrides) == :full
  end

  test "on an equal-specificity tie the stricter level wins" do
    overrides = [{"example.com", :full}, {"example.com", :structure_only}]
    assert Policy.level_for("example.com", overrides: overrides) == :structure_only
  end

  test "an override for an unrelated domain does not apply" do
    assert Policy.level_for("example.com", overrides: [{"other.com", :never}]) == :full
  end

  test "invalid override levels are ignored" do
    assert Policy.level_for("example.com", overrides: [{"example.com", :bogus}]) == :full
  end
end
