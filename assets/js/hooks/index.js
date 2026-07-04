// Aggregates every LiveView hook into one object for the LiveSocket. Each hook
// lives in its own domain module; add new ones here.
import {CornerWidget} from "./corner_widget.js"
import {ScreenshotBridge, EmbeddedBrowser} from "./browser.js"
import {VoiceBridge, VoiceToggle} from "./voice.js"
import {AgentChat, ThinkingTimer, QueueRail} from "./chat.js"
import {CrtAberration} from "./crt.js"
import {CalendarDrag, CalendarPopover} from "./calendar.js"
import {TabStrip} from "./tab_strip.js"
import {SplitResizer} from "./split.js"
import {TerminalView, TermThemePicker} from "./terminal.js"
import {SmokeBackground} from "./smoke_background.js"
import {SvgViewerDock} from "./svg_viewer.js"

export const Hooks = {
  CornerWidget,
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
  SmokeBackground,
  SvgViewerDock,
}
