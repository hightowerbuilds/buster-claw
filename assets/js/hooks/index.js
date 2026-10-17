// Aggregates every LiveView hook into one object for the LiveSocket. Each hook
// lives in its own domain module; add new ones here.
import {Workbench, WorkbenchMenu} from "./workbench.js"
import {BrowserActivity} from "./browser_activity.js"
import {Olympus} from "./olympus.js"
import {Clock, DockClock} from "./clock.js"
import {ScreenshotBridge, EmbeddedBrowser} from "./browser.js"
import {AppIconBridge} from "./app_icon.js"
import {VoiceBridge, VoiceToggle, VoicePicker} from "./voice.js"
import {AgentChat, ThinkingTimer, QueueRail} from "./chat.js"
import {CrtAberration} from "./crt.js"
import {CalendarDrag} from "./calendar.js"
import {TabStrip} from "./tab_strip.js"
import {DutyTab} from "./duty_tab.js"
import {SplitResizer} from "./split.js"
import {TerminalView, TermThemePicker} from "./terminal.js"
import {SmokeBackground} from "./smoke_background.js"
import {ShaderPreview} from "./shader_preview.js"
import {ShaderTimer} from "./shader_timer.js"
import {FileTreeDnd} from "./file_tree_dnd.js"
import {WorkspaceDropzone} from "./workspace_dropzone.js"
import {WorkspaceRail} from "./workspace_rail.js"
import {ChatDropzone} from "./chat_dropzone.js"
import {NotifySound, SoundPreview} from "./notify_sound.js"
import {Composer} from "./composer.js"
import {NoteEditor} from "./note_editor.js"
import {NotesKeys} from "./notes_keys.js"
import {NoteContextMenu, NoteTitle} from "./note_context.js"
import {ClinchManager, RecoveryKey} from "./clinch.js"

export const Hooks = {
  Workbench,
  WorkbenchMenu,
  BrowserActivity,
  Olympus,
  Clock,
  DockClock,
  ScreenshotBridge,
  AppIconBridge,
  VoiceBridge,
  VoiceToggle,
  VoicePicker,
  AgentChat,
  Composer,
  ThinkingTimer,
  QueueRail,
  CrtAberration,
  EmbeddedBrowser,
  CalendarDrag,
  TabStrip,
  DutyTab,
  SplitResizer,
  TerminalView,
  TermThemePicker,
  SmokeBackground,
  ShaderPreview,
  ShaderTimer,
  FileTreeDnd,
  WorkspaceDropzone,
  WorkspaceRail,
  ChatDropzone,
  NotifySound,
  SoundPreview,
  NoteEditor,
  NotesKeys,
  NoteContextMenu,
  NoteTitle,
  ClinchManager,
  RecoveryKey,
}
