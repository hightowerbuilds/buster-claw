//! The Dock icon, at runtime — `APP_ICON_ROADMAP` Phase 1.
//!
//! One AppKit message: `-[NSApplication setApplicationIconImage:]`. Setting it
//! to an `NSImage` replaces the Dock tile for the life of the process; setting
//! it to `nil` restores the icon baked into the bundle. That is why there is no
//! separate reset command — `None` *is* the reset.
//!
//! **This touches no file and breaks no signature.** The bundle's own
//! `Contents/Resources/*.icns` is sealed by `_CodeSignature/CodeResources`;
//! writing it would invalidate the Developer ID signature, the hardened runtime
//! and the notarization ticket at once. Everything here is in-memory and gone on
//! quit, which is exactly the product: the operator's art while they use the app,
//! the app they downloaded in Finder.
//!
//! # THREADING CONTRACT — the inverse of `browser/ffi.rs`
//!
//! That module's rule is "anything round-tripping a completion handler must be
//! called from an **async** command, or the main run loop deadlocks delivering
//! the completion." `setApplicationIconImage:` has **no completion handler**; it
//! is a plain AppKit UI mutation, so it must run **ON** the main thread. This is
//! therefore a **sync** command — Tauri 2 runs those on the main thread — and the
//! neighbouring module's comment is precisely the thing that would talk you into
//! getting it backwards.

#[cfg(target_os = "macos")]
const ALLOWED_EXTS: [&str; 6] = ["png", "jpg", "jpeg", "gif", "tiff", "icns"];

/// Point the Dock at an image, or hand it back to the bundle icon with `None`.
///
/// The path is checked here rather than trusted from the caller. The invoke
/// boundary is reachable by any JS running in the webview, and "the server
/// composed an honest path" is not the same claim as "this command only accepts
/// one". The check is deliberately proportionate: an existing regular file with
/// an image extension. Loading somebody's holiday photo into your own Dock tile
/// is not an exfiltration path — the harm this bounds is a caller aiming
/// `NSImage` at arbitrary bytes, and a wrong-but-real image is a visible,
/// revertible mistake.
#[tauri::command]
pub fn app_icon_set(path: Option<String>) -> Result<(), String> {
    match path {
        None => set_icon(None),
        Some(p) => {
            validate(&p)?;
            set_icon(Some(p))
        }
    }
}

#[cfg(target_os = "macos")]
fn validate(path: &str) -> Result<(), String> {
    let meta = std::fs::symlink_metadata(path).map_err(|e| format!("cannot read icon: {e}"))?;

    // `symlink_metadata` rather than `metadata`, so a symlink is rejected as a
    // symlink instead of being followed to whatever it points at.
    if !meta.is_file() {
        return Err("icon path is not a regular file".into());
    }

    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();

    if !ALLOWED_EXTS.contains(&ext.as_str()) {
        return Err(format!("{ext} is not an image macOS will load"));
    }

    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn validate(_path: &str) -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "macos")]
fn set_icon(path: Option<String>) -> Result<(), String> {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    unsafe {
        let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
        if app.is_null() {
            return Err("no NSApplication".into());
        }

        let image: *mut Object = match path {
            // nil restores the bundle icon. Not a separate code path on purpose:
            // "no custom icon" and "reset" are the same instruction to AppKit.
            None => std::ptr::null_mut(),
            Some(p) => {
                let ns_path: *mut Object = nsstring(&p);
                let alloc: *mut Object = msg_send![class!(NSImage), alloc];
                let img: *mut Object = msg_send![alloc, initWithContentsOfFile: ns_path];

                if img.is_null() {
                    // A file that exists, has the right extension and still does
                    // not decode. Refused rather than passed on as nil, which
                    // would silently look identical to "reset".
                    return Err("macOS could not read that image".into());
                }

                img
            }
        };

        let _: () = msg_send![app, setApplicationIconImage: image];
    }

    Ok(())
}

#[cfg(target_os = "macos")]
unsafe fn nsstring(value: &str) -> *mut objc::runtime::Object {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    let bytes = value.as_ptr() as *const std::ffi::c_void;
    let alloc: *mut Object = msg_send![class!(NSString), alloc];

    // 4 = NSUTF8StringEncoding.
    msg_send![alloc, initWithBytes: bytes length: value.len() encoding: 4usize]
}

/// Nothing to do off macOS. Windows and Linux taskbar icons are a different API
/// each and are out of scope in the roadmap; a stub keeps every call site free of
/// `cfg` noise, matching `browser/ffi.rs`'s per-function pattern.
#[cfg(not(target_os = "macos"))]
fn set_icon(_path: Option<String>) -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
#[cfg(target_os = "macos")]
mod tests {
    use super::*;

    fn tmp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("bc_icon_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    #[test]
    fn rejects_a_path_that_is_not_there() {
        assert!(validate("/nope/missing.png").is_err());
    }

    #[test]
    fn rejects_a_directory() {
        let dir = tmp("adir");
        std::fs::create_dir_all(&dir).unwrap();
        assert!(validate(dir.to_str().unwrap()).is_err());
    }

    #[test]
    fn rejects_a_file_macos_will_not_load() {
        let p = tmp("notes.txt");
        std::fs::write(&p, b"x").unwrap();
        let err = validate(p.to_str().unwrap()).unwrap_err();
        assert!(err.contains("not an image"), "got: {err}");
    }

    #[test]
    fn rejects_an_svg_even_though_the_app_serves_them() {
        // `Pockets.Brand` accepts SVG for in-app chrome; NSImage does not read
        // one, so allowing it here would promise an icon that never appears.
        let p = tmp("logo.svg");
        std::fs::write(&p, b"<svg/>").unwrap();
        assert!(validate(p.to_str().unwrap()).is_err());
    }

    #[test]
    fn rejects_a_symlink_rather_than_following_it() {
        let target = tmp("real.png");
        std::fs::write(&target, b"x").unwrap();
        let link = tmp("link.png");
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&target, &link).unwrap();

        assert!(
            validate(link.to_str().unwrap()).is_err(),
            "a symlink named .png must not be followed to whatever it points at"
        );
    }

    #[test]
    fn accepts_a_real_image_path() {
        let p = tmp("claw.png");
        std::fs::write(&p, b"x").unwrap();
        assert!(validate(p.to_str().unwrap()).is_ok());
    }

    #[test]
    fn extension_check_is_case_insensitive() {
        let p = tmp("CLAW.PNG");
        std::fs::write(&p, b"x").unwrap();
        assert!(validate(p.to_str().unwrap()).is_ok());
    }
}
