fn main() {
    // Register the app-defined terminal + browser commands with the ACL so they
    // can be allowed in capabilities/default.json. Without this, invoking them
    // from the frontend fails with "Command <name> not allowed by ACL".
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "terminal_open",
            "terminal_attach",
            "terminal_input",
            "terminal_resize",
            "terminal_busy",
            "terminal_close",
            "browser_open",
            "browser_set_bounds",
            "browser_navigate",
            "browser_back",
            "browser_forward",
            "browser_reload",
            "browser_new_tab",
            "browser_switch_tab",
            "browser_close_tab",
            "browser_hide",
            "browser_close",
            "browser_screenshot",
            "browser_current",
            "browser_navigate_active",
            "browser_open_tab_active",
            "browser_read_active",
            "browser_find_elements_active",
            "browser_click_active",
            "browser_fill_active",
            "browser_wait_active",
            "browser_extract_active",
            "browser_render_page",
            "browser_app_navigate",
            "browser_reveal_download",
            "browser_set_zoom",
            "browser_find",
            "browser_find_count",
            "browser_set_content_blocking",
        ]),
    ))
    .expect("failed to run tauri-build");
}
