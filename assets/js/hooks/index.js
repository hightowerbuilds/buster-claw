// Aggregates every LiveView hook into one object for the LiveSocket. Each hook
// lives in its own domain module; add new ones here.
import {CornerWidget} from "./corner_widget.js"
import {Clock} from "./clock.js"
import {ScreenshotBridge, EmbeddedBrowser} from "./browser.js"
import {VoiceBridge, VoiceToggle} from "./voice.js"
import {AgentChat, ThinkingTimer, QueueRail} from "./chat.js"
import {CrtAberration} from "./crt.js"
import {CalendarDrag, CalendarPopover} from "./calendar.js"
import {TabStrip} from "./tab_strip.js"
import {SplitResizer} from "./split.js"
import {TerminalView, TermThemePicker} from "./terminal.js"
import {DockNewTerminal} from "./dock_terminal.js"
import {SmokeBackground} from "./smoke_background.js"
import {AudioClip} from "./audio_clip.js"
import {ShaderFace} from "./shader_face.js"
import {ShaderPreview} from "./shader_preview.js"
import {ShaderTimer} from "./shader_timer.js"
import {SvgViewerDock} from "./svg_viewer.js"
import {FileTreeDnd} from "./file_tree_dnd.js"
import {WorkspaceDropzone} from "./workspace_dropzone.js"
import {NotifySound} from "./notify_sound.js"

export const Hooks = {
  CornerWidget,
  Clock,
  ScreenshotBridge,
  VoiceBridge,
  VoiceToggle,
  AgentChat,
  ThinkingTimer,
  QueueRail,
  CrtAberration,
  EmbeddedBrowser,
  CalendarDrag,
  CalendarPopover,
  TabStrip,
  SplitResizer,
  TerminalView,
  TermThemePicker,
  DockNewTerminal,
  SmokeBackground,
  AudioClip,
  ShaderFace,
  ShaderPreview,
  ShaderTimer,
  SvgViewerDock,
  FileTreeDnd,
  WorkspaceDropzone,
  NotifySound,
}
