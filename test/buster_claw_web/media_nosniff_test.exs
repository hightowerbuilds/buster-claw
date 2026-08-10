defmodule BusterClawWeb.MediaNoSniffTest do
  @moduledoc """
  Every route that serves raw workspace bytes must send
  `X-Content-Type-Options: nosniff` — gate `G-35`, promoted out of leftovers as one
  of only two items ever marked HIGH there.

  ## Why this is a named inventory rather than a walk over the router

  Deriving the list from `Phoenix.Router.routes/0` would be shorter and worse. This
  file is meant to be **review-forcing**: adding a route that serves workspace bytes
  should require a human to add a line here and think about whether the header
  applies. A derived list would silently absorb a new route and report success,
  which is the failure mode the original bug already demonstrated — four routes drifted
  out of coverage precisely because nothing named them.

  So the assertion below is a universal *about this list*, and the list is the claim.
  """
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.Library.Artifact

  # Every raw-byte route, and what it takes to make each one answer at all.
  # A 404/400 still passes through the pipeline, so most need no fixture —
  # the header is asserted on whatever status comes back.
  @media_routes [
    {"/appearance/image/home", "uploaded appearance asset"},
    {"/phone/recording?path=nope.mp3", "voicemail audio"},
    {"/music/track/nope.mp3", "music library audio"},
    {"/studio/file/nope.wav", "studio working file"},
    {"/notify/sound", "fallback notification chime"},
    {"/notify/sound/nope.mp3", "named notification chime"},
    {"/ws/image?path=nope.png", "workspace image bytes"},
    {"/pockets/nope/nope.png", "pocket asset bytes"},
    {"/browser/agent-view/nope", "agent mode MJPEG mirror"},
    {"/shaders/nope.wgsl", "raw WGSL"}
  ]

  describe "nosniff on raw-byte routes (G-35)" do
    for {path, label} <- @media_routes do
      test "#{label} (#{path}) sends nosniff", %{conn: conn} do
        conn = get(conn, unquote(path))

        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"],
               """
               #{unquote(path)} answered #{conn.status} without nosniff.

               Its scope in lib/buster_claw_web/router.ex is probably missing
               `pipe_through :media`. See BusterClawWeb.NoSniff.
               """
      end
    end

    test "the header survives a real 200 with actual bytes", %{conn: conn} do
      # A 404 travelling through the pipeline proves the plug runs; this proves the
      # controller's own `put_resp_header` calls do not clobber it on the way out.
      root = Artifact.workspace_root()
      File.mkdir_p!(root)
      png = Path.join(root, "nosniff-fixture.png")
      # Smallest valid PNG header bytes are enough — nothing decodes this.
      File.write!(png, <<137, 80, 78, 71, 13, 10, 26, 10>>)
      on_exit(fn -> File.rm(png) end)

      conn = get(conn, ~p"/ws/image", path: png)

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "the header is sent exactly once, not duplicated by RangeResponse", %{conn: conn} do
      # `RangeResponse` sets nosniff itself for the three audio routes, and those
      # scopes now also pipe through `:media`. `put_resp_header` replaces rather
      # than appends, so this must stay a single value — a duplicated header is
      # malformed and some clients drop the response.
      conn = get(conn, "/music/track/nope.mp3")

      assert length(get_resp_header(conn, "x-content-type-options")) == 1
    end
  end
end
