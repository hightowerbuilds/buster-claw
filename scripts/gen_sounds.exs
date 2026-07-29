# Regenerate the bundled default sound set into priv/static/sounds/.
#
#   mix run scripts/gen_sounds.exs
#
# The output is COMMITTED — this script is the recipe, the repo holds the dish
# (libm's sin can differ across machines in the last ulp, so "regenerate at
# build time" would make artifacts differ by builder). Deterministic on one
# machine: run it twice, `git status` stays clean.
dir = Path.join(["priv", "static", "sounds"])
written = BusterClaw.Notifications.SoundGen.write_all(dir)

IO.puts("wrote #{length(written)} sounds to #{dir}:")
Enum.each(written, fn name ->
  size = File.stat!(Path.join(dir, name)).size
  IO.puts("  #{name} (#{div(size, 1024)} KB)")
end)
