fn main() {
    // Register the app-defined terminal commands with the ACL so they can be
    // allowed in capabilities/default.json. Without this, invoking them from the
    // frontend fails with "Command <name> not allowed by ACL".
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(
            tauri_build::AppManifest::new().commands(&[
                "terminal_open",
                "terminal_input",
                "terminal_resize",
                "terminal_close",
                "workspace_relaunch",
            ]),
        ),
    )
    .expect("failed to run tauri-build");
}
