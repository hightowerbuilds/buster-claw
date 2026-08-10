defmodule BusterClaw.Notifications.Capture.DevicesTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Capture.Devices

  # Captured verbatim from `system_profiler SPAudioDataType -json` on the
  # operator's Mac (2026-08-09). Worth keeping whole rather than trimming to the
  # inputs, because the two devices this parser must DROP are the interesting
  # part: the LG monitor is a DisplayPort output that carries
  # `coreaudio_default_audio_system_device`, and the speakers are a built-in
  # output. A parser that keys off "is default" or "is built-in" instead of "has
  # inputs" would offer the operator a monitor to record into.
  #
  # The iPhone microphone is a Continuity Camera device, and it is the reason the
  # name comes from `_name`: its `coreaudio_input_source` is the literal
  # placeholder string `"spaudio_default"`.
  @real ~S"""
  {
    "SPAudioDataType" : [
      {
        "_items" : [
          {
            "_name" : "LG HDR WQHD",
            "_properties" : "coreaudio_default_audio_system_device",
            "coreaudio_default_audio_system_device" : "spaudio_yes",
            "coreaudio_device_manufacturer" : "Apple Inc.",
            "coreaudio_device_output" : 2,
            "coreaudio_device_srate" : 48000,
            "coreaudio_device_transport" : "coreaudio_device_type_displayport",
            "coreaudio_output_source" : "LG HDR WQHD"
          },
          {
            "_name" : "MacBook Pro Microphone",
            "coreaudio_default_audio_input_device" : "spaudio_yes",
            "coreaudio_device_input" : 1,
            "coreaudio_device_manufacturer" : "Apple Inc.",
            "coreaudio_device_srate" : 48000,
            "coreaudio_device_transport" : "coreaudio_device_type_builtin",
            "coreaudio_input_source" : "MacBook Pro Microphone"
          },
          {
            "_name" : "MacBook Pro Speakers",
            "coreaudio_default_audio_output_device" : "spaudio_yes",
            "coreaudio_device_manufacturer" : "Apple Inc.",
            "coreaudio_device_output" : 2,
            "coreaudio_device_srate" : 48000,
            "coreaudio_device_transport" : "coreaudio_device_type_builtin",
            "coreaudio_output_source" : "MacBook Pro Speakers"
          },
          {
            "_name" : "iPhone (5) Microphone",
            "coreaudio_device_input" : 1,
            "coreaudio_device_manufacturer" : "Apple Inc.",
            "coreaudio_device_srate" : 48000,
            "coreaudio_device_transport" : "coreaudio_device_type_unknown",
            "coreaudio_input_source" : "spaudio_default"
          }
        ],
        "_name" : "coreaudio_device"
      }
    ]
  }
  """

  # No Bluetooth headset is paired with this machine today, and multi-device
  # handling cannot wait for one to be — so this is hand-built to the shape the
  # reporter documents. The transport STRING is not invented: the twelve values
  # `coreaudio_device_type_*` were read out of
  # `/System/Library/SystemProfiler/SPAudioReporter.spreporter`, and
  # `coreaudio_device_type_bluetooth` is one of them.
  #
  # The 16 kHz advertised rate is the HFP/mSBC rate a headset reports once it has
  # been dragged out of A2DP — the exact corpus-poisoning case in STUDIO_ROADMAP
  # V.6, and the reason `transport` is labelled before selection.
  @multi ~S"""
  {
    "SPAudioDataType" : [
      {
        "_items" : [
          {
            "_name" : "MacBook Pro Microphone",
            "coreaudio_device_input" : 1,
            "coreaudio_device_srate" : 48000,
            "coreaudio_device_transport" : "coreaudio_device_type_builtin"
          },
          {
            "_name" : "Luke's AirPods Pro",
            "coreaudio_default_audio_input_device" : "spaudio_yes",
            "coreaudio_device_input" : 1,
            "coreaudio_device_output" : 2,
            "coreaudio_device_srate" : 16000,
            "coreaudio_device_transport" : "coreaudio_device_type_bluetooth"
          },
          {
            "_name" : "Scarlett 2i2 USB",
            "coreaudio_device_input" : 2,
            "coreaudio_device_output" : 2,
            "coreaudio_device_srate" : 96000,
            "coreaudio_device_transport" : "coreaudio_device_type_usb"
          },
          {
            "_name" : "BlackHole 2ch",
            "coreaudio_device_input" : 2,
            "coreaudio_device_output" : 2,
            "coreaudio_device_srate" : 48000,
            "coreaudio_device_transport" : "coreaudio_device_type_virtual"
          }
        ],
        "_name" : "coreaudio_device"
      }
    ]
  }
  """

  # Outputs only — a Mac mini with a monitor and nothing to record with.
  @no_inputs ~S"""
  {
    "SPAudioDataType" : [
      {
        "_items" : [
          {
            "_name" : "LG HDR WQHD",
            "coreaudio_default_audio_output_device" : "spaudio_yes",
            "coreaudio_default_audio_system_device" : "spaudio_yes",
            "coreaudio_device_output" : 2,
            "coreaudio_device_srate" : 48000,
            "coreaudio_device_transport" : "coreaudio_device_type_displayport"
          }
        ],
        "_name" : "coreaudio_device"
      }
    ]
  }
  """

  defp reads(payload), do: [reader: fn -> {:ok, payload} end]

  describe "list/1 against real captured output" do
    test "extracts name, transport, channels, rate and default from the real payload" do
      assert {:ok, devices} = Devices.list(reads(@real))

      assert [
               %{
                 name: "MacBook Pro Microphone",
                 transport: :builtin,
                 channels: 1,
                 sample_rate_hz: 48_000,
                 default?: true
               },
               %{
                 name: "iPhone (5) Microphone",
                 transport: :unknown,
                 channels: 1,
                 sample_rate_hz: 48_000,
                 default?: false
               }
             ] == devices
    end

    test "output-only devices are dropped, including the built-in speakers" do
      assert {:ok, devices} = Devices.list(reads(@real))
      names = Enum.map(devices, & &1.name)

      refute "MacBook Pro Speakers" in names
      refute "LG HDR WQHD" in names
    end

    test "the system-default *output* flag never sets default? on an input" do
      # The LG monitor carries `coreaudio_default_audio_system_device`. Keying
      # off that instead of the input flag would both admit an output device and
      # leave every real input marked non-default.
      assert {:ok, devices} = Devices.list(reads(@real))
      assert [%{name: "MacBook Pro Microphone"}] = Enum.filter(devices, & &1.default?)
    end

    test "default/1 returns the flagged input" do
      assert {:ok, %{name: "MacBook Pro Microphone", transport: :builtin}} =
               Devices.default(reads(@real))
    end
  end

  describe "list/1 transport labelling" do
    test "a Bluetooth input is labelled :bluetooth before anything can select it" do
      assert {:ok, devices} = Devices.list(reads(@multi))

      assert %{transport: :bluetooth, sample_rate_hz: 16_000, channels: 1} =
               Enum.find(devices, &(&1.name == "Luke's AirPods Pro"))
    end

    test "usb, virtual and builtin transports each map to their own atom" do
      assert {:ok, devices} = Devices.list(reads(@multi))

      assert [
               {"MacBook Pro Microphone", :builtin},
               {"Luke's AirPods Pro", :bluetooth},
               {"Scarlett 2i2 USB", :usb},
               {"BlackHole 2ch", :virtual}
             ] == Enum.map(devices, &{&1.name, &1.transport})
    end

    test "a multi-channel interface reports its channel count, not a mono guess" do
      assert {:ok, devices} = Devices.list(reads(@multi))
      assert %{channels: 2, sample_rate_hz: 96_000} = Enum.find(devices, &(&1.channels == 2))
    end

    test "the default input can be the Bluetooth device, and is reported as such" do
      # The trap in the roadmap: the operator's headset may already BE the
      # system default, so `default/1` must not be assumed safe to record with.
      assert {:ok, %{name: "Luke's AirPods Pro", transport: :bluetooth}} =
               Devices.default(reads(@multi))
    end

    test "transports outside the mapped four, and a missing transport key, are :unknown" do
      payload = """
      {"SPAudioDataType":[{"_items":[
        {"_name":"HDMI In","coreaudio_device_input":2,
         "coreaudio_device_transport":"coreaudio_device_type_hdmi"},
        {"_name":"AirPlay In","coreaudio_device_input":2,
         "coreaudio_device_transport":"coreaudio_device_type_airplay"},
        {"_name":"Mystery","coreaudio_device_input":1}
      ]}]}
      """

      assert {:ok, devices} = Devices.list(reads(payload))
      assert [:unknown, :unknown, :unknown] == Enum.map(devices, & &1.transport)
    end
  end

  describe "list/1 with nothing to record with" do
    test "a Mac with only outputs yields an empty list, not an error" do
      assert {:ok, []} == Devices.list(reads(@no_inputs))
    end

    test "default/1 on a Mac with only outputs is :no_input_device" do
      assert {:error, :no_input_device} == Devices.default(reads(@no_inputs))
    end

    test "an empty SPAudioDataType section list yields an empty list" do
      assert {:ok, []} == Devices.list(reads(~S({"SPAudioDataType":[]})))
    end

    test "inputs present but none flagged default is still :no_input_device" do
      payload = """
      {"SPAudioDataType":[{"_items":[
        {"_name":"Scarlett 2i2 USB","coreaudio_device_input":2,
         "coreaudio_device_transport":"coreaudio_device_type_usb"}
      ]}]}
      """

      assert {:ok, [%{name: "Scarlett 2i2 USB"}]} = Devices.list(reads(payload))
      assert {:error, :no_input_device} == Devices.default(reads(payload))
    end
  end

  describe "list/1 on payloads it does not understand" do
    test "output that is not JSON is :unparseable" do
      assert {:error, :unparseable} == Devices.list(reads("system_profiler: bad datatype\n"))
    end

    test "a non-binary payload is :unparseable rather than a raise" do
      assert {:error, :unparseable} == Devices.list(reader: fn -> {:ok, nil} end)
    end

    test "valid JSON without SPAudioDataType is :unexpected_payload" do
      assert {:error, :unexpected_payload} == Devices.list(reads(~S({"SPHardwareDataType":[]})))
    end

    test "SPAudioDataType present but not a list is :unexpected_payload" do
      assert {:error, :unexpected_payload} == Devices.list(reads(~S({"SPAudioDataType":{}})))
    end

    test "an unnamed input fails the whole read rather than yielding a half-built list" do
      # One good device and one nameless one. Returning just the good device
      # would tell the operator their interface is not attached.
      payload = """
      {"SPAudioDataType":[{"_items":[
        {"_name":"MacBook Pro Microphone","coreaudio_device_input":1,
         "coreaudio_device_transport":"coreaudio_device_type_builtin"},
        {"coreaudio_device_input":2,"coreaudio_device_transport":"coreaudio_device_type_usb"}
      ]}]}
      """

      assert {:error, :unexpected_payload} == Devices.list(reads(payload))
      assert {:error, :unexpected_payload} == Devices.default(reads(payload))
    end

    test "an empty-string name is treated as no name" do
      payload = ~S({"SPAudioDataType":[{"_items":[{"_name":"","coreaudio_device_input":1}]}]})
      assert {:error, :unexpected_payload} == Devices.list(reads(payload))
    end

    test "absent channel and rate fields are nil, never invented" do
      payload = """
      {"SPAudioDataType":[{"_items":[
        {"_name":"Odd Mic","coreaudio_default_audio_input_device":"spaudio_yes"}
      ]}]}
      """

      assert {:ok, [%{name: "Odd Mic", channels: nil, sample_rate_hz: nil, default?: true}]} =
               Devices.list(reads(payload))
    end

    test "zero and non-numeric channel counts become nil" do
      payload = """
      {"SPAudioDataType":[{"_items":[
        {"_name":"A","coreaudio_device_input":0,
         "coreaudio_default_audio_input_device":"spaudio_yes"},
        {"_name":"B","coreaudio_device_input":"two","coreaudio_device_srate":"48000"}
      ]}]}
      """

      assert {:ok,
              [%{name: "A", channels: nil}, %{name: "B", channels: nil, sample_rate_hz: nil}]} =
               Devices.list(reads(payload))
    end

    test "a float sample rate is truncated rather than dropped" do
      payload = """
      {"SPAudioDataType":[{"_items":[
        {"_name":"A","coreaudio_device_input":1,"coreaudio_device_srate":44100.0}
      ]}]}
      """

      assert {:ok, [%{sample_rate_hz: 44_100}]} = Devices.list(reads(payload))
    end

    test "devices nested two levels of _items deep are still found" do
      # Older macOS releases group devices under an extra `_items` level; the
      # walk must reach the leaves rather than indexing a fixed depth.
      payload = """
      {"SPAudioDataType":[{"_name":"coreaudio_device","_items":[
        {"_name":"Devices","_items":[
          {"_name":"MacBook Pro Microphone","coreaudio_device_input":1,
           "coreaudio_default_audio_input_device":"spaudio_yes",
           "coreaudio_device_transport":"coreaudio_device_type_builtin"}
        ]}
      ]}]}
      """

      assert {:ok, [%{name: "MacBook Pro Microphone", transport: :builtin, default?: true}]} =
               Devices.list(reads(payload))
    end
  end

  describe "reader failures" do
    test "a reader error passes through list/1 unchanged" do
      assert {:error, :no_profiler} == Devices.list(reader: fn -> {:error, :no_profiler} end)
      assert {:error, :timeout} == Devices.list(reader: fn -> {:error, :timeout} end)

      assert {:error, {:exit_status, 1}} ==
               Devices.list(reader: fn -> {:error, {:exit_status, 1}} end)
    end

    test "default/1 reports the read failure, not absent hardware" do
      # A missing binary must never be indistinguishable from a Mac with no mic.
      assert {:error, :no_profiler} == Devices.default(reader: fn -> {:error, :no_profiler} end)
    end

    test "a reader returning something unrecognised is an error, not a crash" do
      assert {:error, :unreadable} == Devices.list(reader: fn -> :whatever end)
    end
  end

  describe "against the real binary" do
    # system_profiler is a first-party macOS binary, but the suite should not
    # fail on a machine that lacks it — these define themselves out instead.
    @profiler_available File.regular?("/usr/sbin/system_profiler")

    test "every enumerated device matches the documented shape" do
      if @profiler_available do
        assert {:ok, devices} = Devices.list()

        for device <- devices do
          assert %{
                   name: name,
                   transport: transport,
                   channels: channels,
                   sample_rate_hz: rate,
                   default?: default?
                 } = device

          assert is_binary(name) and name != ""
          assert transport in [:builtin, :usb, :bluetooth, :virtual, :unknown]
          assert is_nil(channels) or (is_integer(channels) and channels > 0)
          assert is_nil(rate) or (is_integer(rate) and rate > 0)
          assert is_boolean(default?)
        end

        assert Enum.count(devices, & &1.default?) <= 1
      end
    end

    test "an unmeetable timeout is reported as :timeout, not as no devices" do
      if @profiler_available do
        assert {:error, :timeout} == Devices.list(timeout_ms: 0)
      end
    end
  end
end
