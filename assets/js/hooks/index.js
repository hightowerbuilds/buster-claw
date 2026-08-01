// Aggregates every LiveView hook into one object for the LiveSocket. Each hook
// lives in its own domain module; add new ones here.
import {CornerWidget} from "./corner_widget.js"
import {Clock, DockClock} from "./clock.js"
import {ScreenshotBridge, EmbeddedBrowser} from "./browser.js"
import {VoiceBridge, VoiceToggle} from "./voice.js"
import {AgentChat, ThinkingTimer, QueueRail} from "./chat.js"
import {CrtAberration} from "./crt.js"
import {CalendarDrag} from "./calendar.js"
import {TabStrip} from "./tab_strip.js"
import {SplitResizer} from "./split.js"
import {TerminalView, TermThemePicker} from "./terminal.js"
import {DockNewTerminal} from "./dock_terminal.js"
import {SmokeBackground} from "./smoke_background.js"
import {AudioClip} from "./audio_clip.js"
import {WaveTrim} from "./wave_trim.js"
import {TrackArrange} from "./track_arrange.js"
import {StudioKeys} from "./studio_keys.js"
import {ShaderFace} from "./shader_face.js"
import {ShaderPreview} from "./shader_preview.js"
import {ShaderTimer} from "./shader_timer.js"
import {FileTreeDnd} from "./file_tree_dnd.js"
import {WorkspaceDropzone} from "./workspace_dropzone.js"
import {NotifySound, SoundPreview} from "./notify_sound.js"
import {PortfolioChart} from "./portfolio_chart.js"
import {MusicPlayer} from "./music_player.js"
import {Dtmf} from "./dtmf.js"
import {ChatWindow} from "./chat_window.js"

export const Hooks = {
  PortfolioChart,
  MusicPlayer,
  Dtmf,
  CornerWidget,
  Clock,
  DockClock,
  ScreenshotBridge,
  VoiceBridge,
  VoiceToggle,
  AgentChat,
  ChatWindow,
  ThinkingTimer,
  QueueRail,
  CrtAberration,
  EmbeddedBrowser,
  CalendarDrag,
  TabStrip,
  SplitResizer,
  TerminalView,
  TermThemePicker,
  DockNewTerminal,
  SmokeBackground,
  AudioClip,
  WaveTrim,
  TrackArrange,
  StudioKeys,
  ShaderFace,
  ShaderPreview,
  ShaderTimer,
  FileTreeDnd,
  WorkspaceDropzone,
  NotifySound,
  SoundPreview,
}
