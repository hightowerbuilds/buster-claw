fn main() {
    // Register the app-defined terminal + browser commands with the ACL so they
    // can be allowed in capabilities/default.json. Without this, invoking them
    // from the frontend fails with "Command <name> not allowed by ACL".
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(
            tauri_build::AppManifest::new().commands(&[
                "terminal_open",
                "terminal_attach",
                "terminal_input",
                "terminal_resize",
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
                "browser_app_navigate",
                "browser_reveal_download",
            ]),
        ),
    )
    .expect("failed to run tauri-build");
}
