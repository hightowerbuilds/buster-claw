defmodule BusterClawWeb.WebLayerPurityTest do
  @moduledoc """
  The web layer renders; it does not write the disk or shell out.

  Every `File.*` write and every `System.cmd` under `lib/buster_claw_web` is a
  path the Sentinel layer and the workspace registry cannot see. The 09-05
  review counted nine sites in six files; by 10-16 there were sixteen in ten.
  CODE_QUALITY_SWEEP Phase 5 moved the writes into the contexts that own the
  paths; this is the lockstep that keeps them there. Reads for serving a file
  (`File.stat`, range responses) are presentation and are not gated.
  """
  use ExUnit.Case, async: true

  @forbidden ~r/\bSystem\.cmd\(|\bFile\.(write|write!|cp|cp!|cp_r|rm|rm!|rm_rf|mkdir|mkdir!|mkdir_p|mkdir_p!|rename|touch|ln|ln_s)\(/

  test "no web-layer file writes or shell-outs" do
    offenders =
      Path.wildcard("lib/buster_claw_web/**/*.{ex,heex}")
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(@forbidden, line) end)
        |> Enum.map(fn {line, n} -> "#{file}:#{n}: #{String.trim(line)}" end)
      end)

    assert offenders == [],
           "the web layer writes the disk or shells out — move it into the context " <>
             "that owns the path:\n  " <> Enum.join(offenders, "\n  ")
  end
end
