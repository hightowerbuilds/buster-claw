//! The native application menu — the standard macOS menu minus Cmd-W, plus
//! the Tabs menu that carries every keyboard accelerator.
//!
//! Split out of main.rs on 10-16 (CODE_QUALITY_SWEEP Phase 8). Nothing here
//! handles an event: menu item ids route through `browser::handle_menu_shortcut`
//! (registered in main.rs), which picks the webview the shortcut belongs to.

/// Build the application menu: the standard macOS menu with the Window →
/// "Close Window" item (Cmd-W) removed, so the JS-side tab-close handler can
/// fully own Cmd-W instead of the OS closing the whole window out from under it.
///
/// Tauri's `Menu::default` binds Cmd-W to a native `close_window` predefined
/// item, and that accelerator fires regardless of the webview's `keydown`
/// capture handler — so with a single tab open Cmd-W would close the entire
/// window before JS ever saw it. We replicate the default macOS menu verbatim
/// minus that one item; everything else (Quit/Cmd-Q, copy/paste, minimize,
/// fullscreen, etc.) stays intact so the app still feels native. The red
/// traffic-light X and Cmd-Q are untouched and still close/quit normally.
#[cfg(target_os = "macos")]
pub(crate) fn build_app_menu(
    handle: &tauri::AppHandle,
) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    use tauri::menu::{AboutMetadataBuilder, Menu, PredefinedMenuItem, Submenu};

    let pkg_info = handle.package_info();
    let config = handle.config();
    let about_metadata = AboutMetadataBuilder::new()
        .name(Some(pkg_info.name.clone()))
        .version(Some(pkg_info.version.to_string()))
        .copyright(config.bundle.copyright.clone())
        .authors(config.bundle.publisher.clone().map(|p| vec![p]))
        .build();

    let app_menu = Submenu::with_items(
        handle,
        pkg_info.name.clone(),
        true,
        &[
            &PredefinedMenuItem::about(handle, None, Some(about_metadata))?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::services(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::hide(handle, None)?,
            &PredefinedMenuItem::hide_others(handle, None)?,
            &PredefinedMenuItem::show_all(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::quit(handle, None)?,
        ],
    )?;

    let edit_menu = Submenu::with_items(
        handle,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(handle, None)?,
            &PredefinedMenuItem::redo(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::cut(handle, None)?,
            &PredefinedMenuItem::copy(handle, None)?,
            &PredefinedMenuItem::paste(handle, None)?,
            &PredefinedMenuItem::select_all(handle, None)?,
        ],
    )?;

    let view_menu = Submenu::with_items(
        handle,
        "View",
        true,
        &[&PredefinedMenuItem::fullscreen(handle, None)?],
    )?;

    // Standard Window menu MINUS `PredefinedMenuItem::close_window` (Cmd-W).
    // Dropping that item is the whole point of this custom menu — see the doc
    // comment above. The trailing separator that preceded it in the default
    // menu is dropped with it.
    let window_menu = Submenu::with_items(
        handle,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(handle, None)?,
            &PredefinedMenuItem::maximize(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::fullscreen(handle, None)?,
        ],
    )?;

    let tabs_menu = build_tabs_menu(handle)?;

    Menu::with_items(
        handle,
        &[&app_menu, &edit_menu, &view_menu, &tabs_menu, &window_menu],
    )
}

/// The Tabs menu carries every keyboard shortcut (⌘T/⌘W/⌘R/⌘L, ⌘⇧[/],
/// ⌘1-9). Accelerators must live on menu items on macOS — they fire regardless
/// of which webview has focus, which is exactly what the browser needs (its
/// chrome/content webviews can't be reached by the app webview's JS keydown
/// handlers). Events route through `browser::handle_menu_shortcut`: the shown
/// browser surface's chrome first, else the app webview's TabStrip.
#[cfg(target_os = "macos")]
fn build_tabs_menu(handle: &tauri::AppHandle) -> tauri::Result<tauri::menu::Submenu<tauri::Wry>> {
    use tauri::menu::{IsMenuItem, MenuItem, PredefinedMenuItem, Submenu};

    // Prefer the accelerator; fall back to a plain item rather than failing
    // the whole menu build if the accelerator string doesn't parse.
    let item = |id: &str, label: &str, accel: &str| {
        MenuItem::with_id(handle, id, label, true, Some(accel))
            .or_else(|_| MenuItem::with_id(handle, id, label, true, None::<&str>))
    };

    let new_tab = item("bc_new_tab", "New Tab", "CmdOrCtrl+T")?;
    let close_tab = item("bc_close_tab", "Close Tab", "CmdOrCtrl+W")?;
    let sep1 = PredefinedMenuItem::separator(handle)?;
    let reload = item("bc_reload", "Reload Page", "CmdOrCtrl+R")?;
    let focus_address = item("bc_focus_address", "Open Location", "CmdOrCtrl+L")?;
    let find = item("bc_find", "Find…", "CmdOrCtrl+F")?;
    let zoom_in = item("bc_zoom_in", "Zoom In", "CmdOrCtrl+=")?;
    let zoom_out = item("bc_zoom_out", "Zoom Out", "CmdOrCtrl+-")?;
    let zoom_reset = item("bc_zoom_reset", "Actual Size", "CmdOrCtrl+0")?;
    let toggle_sidebar = item("bc_toggle_sidebar", "Toggle Tab Sidebar", "CmdOrCtrl+B")?;
    let sep2 = PredefinedMenuItem::separator(handle)?;
    let prev_tab = item("bc_prev_tab", "Previous Tab", "CmdOrCtrl+Shift+[")?;
    let next_tab = item("bc_next_tab", "Next Tab", "CmdOrCtrl+Shift+]")?;
    let sep3 = PredefinedMenuItem::separator(handle)?;

    // ⌘1 ⌘2 ⌘3 jump to the three places the app has — the work area,
    // Settings and the Browser (operator, 10-15) — and there is no ⌘4–9. The
    // ids keep the `bc_tab_N` shape so the JS router is unchanged.
    let numbered: Vec<tauri::menu::MenuItem<tauri::Wry>> =
        [(1, "Work Area"), (2, "Settings"), (3, "Browser")]
            .iter()
            .map(|(n, label)| item(&format!("bc_tab_{n}"), label, &format!("CmdOrCtrl+{n}")))
            .collect::<Result<_, _>>()?;

    let mut items: Vec<&dyn IsMenuItem<tauri::Wry>> = vec![
        &new_tab,
        &close_tab,
        &sep1,
        &reload,
        &focus_address,
        &find,
        &zoom_in,
        &zoom_out,
        &zoom_reset,
        &sep2,
        &toggle_sidebar,
        &prev_tab,
        &next_tab,
        &sep3,
    ];
    for it in &numbered {
        items.push(it);
    }

    Submenu::with_items(handle, "Tabs", true, &items)
}

/// Non-macOS targets keep Tauri's stock menu unchanged — the Cmd-W concern is
/// macOS-specific and this app ships only on macOS.
#[cfg(not(target_os = "macos"))]
pub(crate) fn build_app_menu(
    handle: &tauri::AppHandle,
) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    tauri::menu::Menu::default(handle)
}
