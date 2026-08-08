defmodule BusterClaw.Scene3d.Labels do
  @moduledoc """
  Label layout: projected label anchors in, a set of `t:BusterClaw.Scene3d.Types.placed_label/0`
  that **do not overlap each other** out. Pure arithmetic — no processes, no IO,
  no state, and no knowledge of SVG.

  ## The failure this exists to fix

  A model asked for a map of Puget Sound produced thirteen labels clustered over
  a few hundred square units of card. Drawn the obvious way — every label at the
  same size, at the point it names — the result was "Deception Pass Bridge" on
  top of "Fidalgo Island" on top of "Oak Harbor": a pile of words with not one of
  them readable. Zero of thirteen labels delivered, from thirteen correct
  positions. Placement is not a rendering detail; it is the difference between a
  map and a smudge.

  So this stage owns three decisions the renderer must not second-guess: how big
  the text is, where it actually goes, and which labels do not get drawn at all.

  ## Dropping labels is the point, not a bug

  When there is no room, a label is **omitted from the result**. That is a
  deliberate trade and worth defending, because "drop the user's data" always
  reads as wrong at first glance. The card that carries this picture also carries
  a caption naming everything in the scene, so a dropped label is not lost
  information — it is the same information, moved somewhere it can be read. The
  choice is between a legible picture plus a complete list, or thirteen
  overlapping words and neither. Nothing is gained by drawing text that cannot be
  read on top of other text that now also cannot be read.

  A caller that wants "all or nothing" should compare `length/1` against its
  input, not ask this module to relax.

  ## Text extent is estimated, and that is a real limit

  There is no font metrics engine here — no font file, no shaping, no renderer to
  ask. The width of a string is therefore **guessed** from its characters, using a
  small table of per-class advance widths in ems (narrow `il.,`, wide `mwMW`,
  caps, lowercase, space, and a catch-all), summed and multiplied by the font
  size. Roughly 0.52 em per character for mixed-case Latin text.

  The single flat ratio the obvious version of this uses (~0.55 em per glyph) is
  wrong in a way that matters: all-caps text averages nearer 0.64 em, so a flat
  ratio under-measures `"OAK HARBOR"` by about 15% of its width — several times
  the gap kept between boxes — and two such labels placed side by side would
  genuinely collide. The per-class table costs six clauses and removes that whole
  class of error.

  What remains wrong, stated plainly:

  - **Condensed or wide font stacks shift every width uniformly.** The layout
    tolerates roughly ±0.05 em of systematic error on short labels before two
    horizontally-adjacent boxes touch, and the tolerance shrinks as labels get
    longer — a pair of 12-character labels tolerates about ±0.03 em. Beyond that,
    text can visibly kiss. Under-estimating is the dangerous direction, so the
    table is tuned to run slightly *generous*: the common failure is dropping a
    label that would have fitted, which is invisible, rather than overlapping one,
    which is not.
  - **CJK and emoji are assumed full-width (1.0 em).** Right for CJK, wrong for
    some emoji sequences, which may be measured several times over if they are
    built from multiple codepoints.
  - **Kerning and ligatures are ignored**, which is worth well under a percent.

  The estimate is also the *contract* the renderer must honour: boxes are
  **centred on `at`**, so `Scene3d.Svg` has to draw with a centred horizontal
  anchor and a middle baseline. Draw the same text left-aligned from `at` and
  every box here is off by half its width, which makes this module's guarantee
  a fiction. `box/2` is public so a renderer (or a test) can ask for the exact
  rectangle rather than re-deriving it and drifting.

  ## Size falls off with density

  Three labels can be large; thirteen cannot. Font size is uniform across a
  layout — mixed sizes read as emphasis, and nothing here means to emphasise
  anything — and shrinks as `count ** -0.35`, from 5.5% of the frame's short side
  at one label to about 2.3% at thirteen, with a hard floor at 1.8%. The exponent
  is gentler than the `1/sqrt(n)` that area-packing suggests, because labels are
  wide and short: halving the size only buys twice the rows, and text that is
  small enough to fit is not worth fitting. The floor is where that argument runs
  out — below it, dropping the label is strictly better than drawing it, so the
  size stops falling and the collision test starts dropping instead.

  ## Greedy, nearest-first

  Placement is a single greedy pass in ascending `depth`: the label nearest the
  camera gets first pick of the card. That order is not arbitrary. Near labels
  name the foreground the eye reads first; near geometry is drawn last and
  largest, so a near label pushed away from its subject is the one most obviously
  wrong; and depth is the only ranking already in the data that is not simply
  authoring order. The cost of greedy is the usual one — an early label can take
  a spot that would have suited two later ones better — and it is accepted. This
  is a chat card, not a cartographic engine; a simulated-annealing label placer
  would be several hundred lines to move a word two millimetres.

  Each label tries its anchor first, then a ring of offsets around it, then the
  anchor clamped inside the frame. The first candidate that hits nothing already
  placed and stays inside the viewbox wins; if none does, the label is dropped.
  Anything not placed at its anchor is marked `leader: true` so the renderer can
  draw a hairline back to what it names — an offset label with no leader points
  at nothing.

  Ties in `depth` keep input order, and nothing here iterates a map, so the same
  input always produces the same output.

  ## Total, including on labels that cannot exist

  A label whose `text` is not a binary, or is blank, or whose `at` is not a pair
  of numbers, is **skipped** — same treatment as one that would not fit. It does
  not raise.

  `Scene3d.validate/1` already guarantees label text is a string, so through the
  normal pipeline this is unreachable. It is here anyway, for two reasons. The
  first is structural: every stage of Scene3D returns rather than raises, and
  this one runs immediately before markup reaches a live view — a crash here is
  a crashed LiveView, which is the one failure mode the whole channel is built to
  avoid. The second is that "unreachable" is a property of today's callers.
  This module is public and pure and reads like a utility, which is exactly the
  kind of thing a second caller reaches for without re-reading the validator.
  Checking is four lines; the guarantee is the point of the feature.
  """

  alias BusterClaw.Scene3d.Types

  @typedoc "The frame's viewbox, `{min_x, min_y, width, height}`, in SVG user units."
  @type viewbox :: {float(), float(), float(), float()}

  @typedoc "An axis-aligned rectangle, `{min_x, min_y, max_x, max_y}`, in SVG user units."
  @type box :: {float(), float(), float(), float()}

  # Font size for a single label, as a fraction of the frame's short side.
  @base_fraction 0.055

  # The floor. Below this, text on a chat-sized card is not worth drawing, so we
  # stop shrinking and start dropping.
  @min_fraction 0.018

  # How fast size falls off with label count. See the moduledoc: gentler than
  # 1/sqrt(n) on purpose.
  @falloff 0.35

  # A uniform multiplier on the estimated text width, for callers who know their
  # font stack is condensed or wide. 1.0 means "trust the table".
  @em_scale 1.0

  # Clear space kept between two label boxes, in ems of the font size. This is
  # the whole margin the width estimate has to be wrong within.
  @pad_ems 0.35

  # How far the candidate ring reaches, in multiples of the label's own size.
  # Three rings is enough to step a label clear of two neighbours; past that the
  # label is so far from its anchor that the leader line is doing all the work
  # and dropping it is more honest.
  @ring_radii [1.0, 2.0, 3.0]

  # Compass directions, in preference order: straight up, straight down, then the
  # diagonals, then sideways last. Vertical first because stacked text is how
  # people expect crowded labels to resolve, and because a sideways step has to
  # clear a whole label width to achieve what a line's height does vertically.
  # SVG's Y grows downward, so -1 is up.
  @ring_dirs [
    {0.0, -1.0},
    {0.0, 1.0},
    {1.0, -1.0},
    {-1.0, -1.0},
    {1.0, 1.0},
    {-1.0, 1.0},
    {1.0, 0.0},
    {-1.0, 0.0}
  ]

  @doc """
  Lay out projected labels so that none of them overlap.

  Returns the labels that were placed, **nearest to the camera first**. Labels
  that could not be placed are absent; see the moduledoc for why that is the
  intended outcome rather than a failure.

  Total: an empty list, a degenerate viewbox, a label longer than the whole frame
  and a structurally junk label all return a well-formed list rather than
  raising. A label is **skipped** unless its `text` is a non-blank binary and its
  `at` and `depth` are numbers — see the moduledoc for why that check lives here
  and not only in the caller.

  ## Options

    * `:size_fraction` — font size for a single label, as a fraction of the
      frame's short side (default `#{@base_fraction}`).
    * `:min_fraction` — the floor size, same units (default `#{@min_fraction}`).
    * `:falloff` — exponent on label count (default `#{@falloff}`); `0.0`
      disables density scaling entirely.
    * `:em_scale` — uniform multiplier on estimated text width, for a font stack
      known to be condensed or wide (default `#{@em_scale}`).
    * `:pad_ems` — clear space kept between boxes, in ems (default `#{@pad_ems}`).
  """
  @spec layout([Types.poly_label()], viewbox(), keyword()) :: [Types.placed_label()]
  def layout(labels, viewbox, opts \\ [])

  def layout(labels, {_min_x, _min_y, width, height} = viewbox, opts) do
    # Filter before counting: three good labels and two malformed ones should be
    # sized as three labels, not five.
    case Enum.filter(labels, &placeable?/1) do
      [] -> []
      usable -> lay_out(usable, min(width, height), viewbox, opts)
    end
  end

  @doc """
  The rectangle a placed label is estimated to occupy, `{min_x, min_y, max_x, max_y}`.

  Centred on `at`, which is the convention the renderer owes this module. Public
  because both `Scene3d.Svg` (for backdrops or debugging) and the tests need the
  *same* estimate this module placed with — re-deriving it anywhere else is how
  the two drift apart and the no-overlap guarantee quietly stops being true.

  Pass the same `:em_scale` given to `layout/3`, or the box will not match.
  """
  @spec box(Types.placed_label(), keyword()) :: box()
  def box(label, opts \\ []) do
    {width, height} = extent(label.text, label.size, Keyword.get(opts, :em_scale, @em_scale))

    box_at(label.at, width, height)
  end

  # ── Sizing ──────────────────────────────────────────────────────────────────

  @spec lay_out([Types.poly_label()], float(), viewbox(), keyword()) :: [Types.placed_label()]
  defp lay_out(labels, short_side, viewbox, opts) do
    size = font_size(length(labels), short_side, opts)

    if size > 0.0 do
      place_all(labels, %{
        size: size,
        em: Keyword.get(opts, :em_scale, @em_scale),
        pad: Keyword.get(opts, :pad_ems, @pad_ems) * size,
        viewbox: viewbox
      })
    else
      # A frame with no extent cannot hold text of any size. Nothing to say.
      []
    end
  end

  # Everything this module does downstream is arithmetic on `at` and character
  # arithmetic on `text`, so anything that is not both is skipped here rather
  # than allowed to raise several frames deeper. Blank text is skipped for a
  # different reason: it measures as a zero-width box, so it "fits" anywhere and
  # would spend a slot placing nothing.
  @spec placeable?(term()) :: boolean()
  defp placeable?(%{at: {x, y}, text: text, depth: depth})
       when is_number(x) and is_number(y) and is_binary(text) and is_number(depth) do
    String.trim(text) != ""
  end

  defp placeable?(_label), do: false

  @spec font_size(pos_integer(), float(), keyword()) :: float()
  defp font_size(count, short_side, opts) do
    base = Keyword.get(opts, :size_fraction, @base_fraction)
    minimum = Keyword.get(opts, :min_fraction, @min_fraction)
    falloff = Keyword.get(opts, :falloff, @falloff)

    fraction = max(base / :math.pow(count, falloff), minimum)

    fraction * max(short_side, 0.0)
  end

  # ── Placement ───────────────────────────────────────────────────────────────

  @spec place_all([Types.poly_label()], map()) :: [Types.placed_label()]
  defp place_all(labels, ctx) do
    {placed, _taken} =
      labels
      |> Enum.sort_by(& &1.depth)
      |> Enum.reduce({[], []}, fn label, {placed, taken} ->
        case place(label, Map.put(ctx, :taken, taken)) do
          {:ok, result, box} -> {[result | placed], [box | taken]}
          :drop -> {placed, taken}
        end
      end)

    Enum.reverse(placed)
  end

  @spec place(Types.poly_label(), map()) :: {:ok, Types.placed_label(), box()} | :drop
  defp place(label, ctx) do
    {width, height} = extent(label.text, ctx.size, ctx.em)
    ctx = ctx |> Map.put(:w, width) |> Map.put(:h, height)

    label.at
    |> candidates(ctx)
    |> Enum.find_value(:drop, &accept(&1, label, ctx))
  end

  # `nil` rather than `false` on rejection: `Enum.find_value/3` wants a falsy
  # value to keep looking, and the accepted value is the result itself.
  @spec accept(Types.vec2(), Types.poly_label(), map()) ::
          {:ok, Types.placed_label(), box()} | nil
  defp accept(position, label, ctx) do
    box = box_at(position, ctx.w, ctx.h)

    if inside?(box, ctx.viewbox) and not collides?(box, ctx.taken, ctx.pad) do
      {:ok, placed(label, position, ctx.size), box}
    end
  end

  @spec placed(Types.poly_label(), Types.vec2(), float()) :: Types.placed_label()
  defp placed(label, position, size) do
    %{
      at: position,
      anchor: label.at,
      text: label.text,
      size: size,
      # Compared by value: only the anchor candidate (and a clamp that had
      # nothing to clamp) can land exactly on the anchor.
      leader: position != label.at
    }
  end

  # Anchor first — a label on the thing it names needs no explaining — then rings
  # of increasing radius, then one last try with the anchor pulled inside the
  # frame, which rescues labels on subjects at the very edge of the card.
  @spec candidates(Types.vec2(), map()) :: [Types.vec2()]
  defp candidates({x, y} = anchor, ctx) do
    # A sideways step must clear half this label's own width plus a line's worth
    # of air; a vertical step only needs a line and a bit.
    step_x = ctx.w / 2.0 + ctx.h
    step_y = ctx.h * 1.4

    ring =
      for radius <- @ring_radii, {dx, dy} <- @ring_dirs do
        {x + dx * radius * step_x, y + dy * radius * step_y}
      end

    [anchor] ++ ring ++ [clamped(anchor, ctx)]
  end

  # Nudge the box fully inside the frame. When the label is wider than the frame
  # the bounds cross, `clamp/3` returns the upper bound, and `inside?/2` then
  # rejects it — which is correct: it never could have fitted.
  @spec clamped(Types.vec2(), map()) :: Types.vec2()
  defp clamped({x, y}, ctx) do
    {min_x, min_y, width, height} = ctx.viewbox

    {
      clamp(x, min_x + ctx.w / 2.0, min_x + width - ctx.w / 2.0),
      clamp(y, min_y + ctx.h / 2.0, min_y + height - ctx.h / 2.0)
    }
  end

  # ── Boxes ───────────────────────────────────────────────────────────────────

  @spec box_at(Types.vec2(), float(), float()) :: box()
  defp box_at({x, y}, width, height) do
    {x - width / 2.0, y - height / 2.0, x + width / 2.0, y + height / 2.0}
  end

  @spec collides?(box(), [box()], float()) :: boolean()
  defp collides?(box, taken, pad), do: Enum.any?(taken, &overlaps?(&1, box, pad))

  # Interval overlap on both axes, with `pad` of clear space demanded between
  # them. Strict comparisons, so two boxes exactly `pad` apart are fine.
  @spec overlaps?(box(), box(), float()) :: boolean()
  defp overlaps?({ax1, ay1, ax2, ay2}, {bx1, by1, bx2, by2}, pad) do
    ax1 < bx2 + pad and bx1 - pad < ax2 and ay1 < by2 + pad and by1 - pad < ay2
  end

  @spec inside?(box(), viewbox()) :: boolean()
  defp inside?({x1, y1, x2, y2}, {min_x, min_y, width, height}) do
    x1 >= min_x and y1 >= min_y and x2 <= min_x + width and y2 <= min_y + height
  end

  # ── Estimated text metrics ──────────────────────────────────────────────────

  @spec extent(String.t(), float(), float()) :: {float(), float()}
  defp extent(text, size, em_scale) do
    {text_ems(text) * size * em_scale, size}
  end

  @spec text_ems(String.t()) :: float()
  defp text_ems(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0.0, fn codepoint, total -> total + glyph_em(codepoint) end)
  end

  # Advance widths in ems, by character class, eyeballed against the app's sans
  # stack. Every number here is an approximation — see the moduledoc — and they
  # lean generous, because over-estimating drops a label that would have fitted
  # while under-estimating draws two labels on top of each other.
  @spec glyph_em(char()) :: float()
  defp glyph_em(?\s), do: 0.28

  defp glyph_em(codepoint)
       when codepoint in [
              ?i,
              ?j,
              ?l,
              ?t,
              ?f,
              ?r,
              ?I,
              ?.,
              ?,,
              ?:,
              ?;,
              ?',
              ?!,
              ?|,
              ?(,
              ?),
              ?[,
              ?],
              ?/
            ],
       do: 0.30

  defp glyph_em(codepoint) when codepoint in [?m, ?w, ?M, ?W, ?@, ?%], do: 0.88
  defp glyph_em(codepoint) when codepoint in ?A..?Z, do: 0.64
  # CJK, and anything else living up in the wide planes, is full-width.
  defp glyph_em(codepoint) when codepoint >= 0x2E80, do: 1.0
  defp glyph_em(_codepoint), do: 0.52

  @spec clamp(float(), float(), float()) :: float()
  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)
end
