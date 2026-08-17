defmodule BusterClaw.Sketch.ImageInfoTest do
  # Header parsing, checked against bytes rather than against my reading of the
  # specs. The PNG and GIF fixtures are real files decoded from base64; the JPEG
  # and WebP ones are assembled here, byte by byte, from the parts the parser
  # actually looks at.
  use ExUnit.Case, async: true

  alias BusterClaw.Sketch.ImageInfo

  # A real 2x3 PNG (produced once, pasted here) — signature, IHDR, IDAT, IEND.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAFElEQVR4nGP8" <>
           "z8Dwn4GBgYEJRAAAHAAD/1a0lqcAAAAASUVORK5CYII="
       )

  # A real 1x1 transparent GIF.
  @gif Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

  # JPEG: SOI, an APP0 segment to be skipped, then SOF0 carrying 7 high by 5 wide.
  defp jpeg(width, height) do
    app0 = <<0xFF, 0xE0, 0x00, 0x10, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>
    sof0 = <<0xFF, 0xC0, 0x00, 0x11, 8, height::16, width::16, 3>>
    <<0xFF, 0xD8>> <> app0 <> sof0 <> <<0xFF, 0xD9>>
  end

  defp webp_lossy(width, height) do
    body = <<"VP8 ", 0::32, 0::24, 0x9D, 0x01, 0x2A, width::little-16, height::little-16>>
    <<"RIFF", byte_size(body) + 4::32, "WEBP">> <> body
  end

  defp webp_extended(width, height) do
    body = <<"VP8X", 10::32, 0::32, width - 1::little-24, height - 1::little-24>>
    <<"RIFF", byte_size(body) + 4::32, "WEBP">> <> body
  end

  describe "identifying and measuring" do
    test "a real PNG" do
      assert {:ok, %{format: :png, width: 2, height: 3}} = ImageInfo.inspect_binary(@png)
    end

    test "a real GIF" do
      assert {:ok, %{format: :gif, width: 1, height: 1}} = ImageInfo.inspect_binary(@gif)
    end

    test "a JPEG, found by walking past a segment that is not a frame" do
      # The APP0 in the fixture is skipped by its own declared length. A parser
      # that searched for the SOF byte pattern instead would eventually find one
      # inside compressed data and report nonsense.
      assert {:ok, %{format: :jpeg, width: 5, height: 7}} = ImageInfo.inspect_binary(jpeg(5, 7))
    end

    test "JPEG stores height before width, which is the easy one to invert" do
      assert {:ok, %{width: 640, height: 480}} = ImageInfo.inspect_binary(jpeg(640, 480))
    end

    test "lossy and extended WebP" do
      assert {:ok, %{format: :webp, width: 12, height: 34}} =
               ImageInfo.inspect_binary(webp_lossy(12, 34))

      # Extended stores each dimension minus one, so an off-by-one here is a
      # silently wrong size rather than a failure.
      assert {:ok, %{format: :webp, width: 800, height: 600}} =
               ImageInfo.inspect_binary(webp_extended(800, 600))
    end

    test "GIF is little-endian where the others are big-endian" do
      # The one place these formats disagree about byte order, so it is the one
      # place a copy-paste between clauses produces a plausible wrong number.
      gif = <<"GIF89a", 320::little-16, 240::little-16, 0, 0, 0>>

      assert {:ok, %{width: 320, height: 240}} = ImageInfo.inspect_binary(gif)
    end
  end

  describe "refusing" do
    test "an extension is a claim; the bytes are the evidence" do
      # The whole reason this module exists. A file called `screenshot.png` that
      # is a shell script must not be written into the workspace and served back.
      assert {:error, :unsupported} = ImageInfo.inspect_binary("#!/bin/sh\nrm -rf /")
      assert {:error, :unsupported} = ImageInfo.inspect_binary("<svg onload=alert(1)>")
      assert {:error, :unsupported} = ImageInfo.inspect_binary(<<0, 0, 0, 0>>)
      assert {:error, :unsupported} = ImageInfo.inspect_binary("")
    end

    test "SVG is not on the list, deliberately" do
      # An SVG is a document that can carry script, not a raster image. Accepting
      # one here would put markup of someone else's behind an <image href>, which
      # is the exact surface `SvgViewer` needs a sanitiser to survive.
      svg = ~s(<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>)

      assert {:error, :unsupported} = ImageInfo.inspect_binary(svg)
      refute :svg in ImageInfo.formats()
    end

    test "a truncated header is refused rather than half-read" do
      assert {:error, :unsupported} = ImageInfo.inspect_binary(binary_part(@png, 0, 12))
      assert {:error, :truncated} = ImageInfo.inspect_binary(<<0xFF, 0xD8, 0xFF, 0xC0, 0x00>>)
    end

    test "a JPEG whose scan starts before any frame header" do
      assert {:error, :no_frame_header} =
               ImageInfo.inspect_binary(<<0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02>>)
    end

    test "zero and absurd dimensions" do
      assert {:error, :zero_dimension} = ImageInfo.inspect_binary(jpeg(0, 10))
      assert {:error, :too_large} = ImageInfo.inspect_binary(jpeg(50_000, 10))
    end

    test "a non-binary is refused rather than crashing" do
      assert {:error, :not_binary} = ImageInfo.inspect_binary(:png)
      assert {:error, :not_binary} = ImageInfo.inspect_binary(nil)
    end
  end

  describe "inspect_file/1" do
    @describetag :tmp_dir

    test "reads a real file", %{tmp_dir: dir} do
      path = Path.join(dir, "x.png")
      File.write!(path, @png)

      assert {:ok, %{format: :png, width: 2, height: 3}} = ImageInfo.inspect_file(path)
    end

    test "a missing or empty file", %{tmp_dir: dir} do
      empty = Path.join(dir, "empty.png")
      File.write!(empty, "")

      assert {:error, :not_found} = ImageInfo.inspect_file(Path.join(dir, "nope.png"))
      assert {:error, :empty} = ImageInfo.inspect_file(empty)
    end

    test "reads a bounded prefix, not the whole file", %{tmp_dir: dir} do
      # A native drop names a path we did not choose. Reading it whole to find a
      # 24-byte header would let a 4 GB file decide how much memory this costs.
      path = Path.join(dir, "big.png")
      File.write!(path, @png <> :binary.copy(<<0>>, 5_000_000))

      assert {:ok, %{format: :png}} = ImageInfo.inspect_file(path)
    end
  end

  describe "the format table" do
    test "every recognised format has an extension and a media type" do
      # A format that parses but cannot be stored or served is a file that lands
      # in the workspace and 404s when the page asks for it back.
      for format <- ImageInfo.formats() do
        assert is_binary(ImageInfo.extension(format))
        assert String.starts_with?(ImageInfo.media_type(format), "image/")
      end
    end
  end
end
