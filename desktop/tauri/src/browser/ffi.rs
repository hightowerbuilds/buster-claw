//! The objc/WKWebView FFI boundary — the four operations WebKit only offers
//! through native API, each with a non-macOS stub: evaluateJavaScript with a
//! result (every automation command funnels through it), the content-blocker
//! rule store, page-title reads, and snapshot capture. THREADING CONTRACT:
//! anything that round-trips a completion handler must be called from an
//! async command (worker thread) — a sync command runs on the main thread and
//! deadlocks the run loop that delivers the completion.

// Native content blocking (roadmap Phase 4). A curated EasyList subset of the
// highest-impact ad/tracker/analytics hosts, compiled once by WebKit's own
// WKContentRuleListStore and applied to every content webview — Safari's
// content-blocker engine, uniquely available to us because we chose WKWebView.
// Bump the identifier's version suffix whenever blocklist.json changes so the
// store recompiles instead of serving a stale cached list.
const BLOCKLIST_ID: &str = "buster-blocklist-v1";
#[cfg(target_os = "macos")]
const BLOCKLIST_JSON: &str = include_str!("../blocklist.json");

// Run JS in a webview and return its (string) result — the completion-handler
// variant of `eval`. Same objc bridge pattern as the screenshot/title paths:
// THREADING CONTRACT: callers must be `async` commands (tokio worker), never
// sync ones. In Tauri 2 sync commands run ON the main thread; from there
// `with_webview` executes inline and `evaluateJavaScript` gets called, but its
// completion is delivered by the main run loop — which this recv is blocking.
// The completion can then never arrive and every call times out (observed live
// via `sample`: recv_timeout parked on DispatchQueue_1). From a worker thread
// the closure is dispatched to a free main loop and the round-trip completes.
#[cfg(target_os = "macos")]
pub(super) fn eval_with_result(webview: &tauri::Webview, js: &str) -> Result<String, String> {
    use block::ConcreteBlock;
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    let (tx, rx) = channel::<Result<String, String>>();
    let js = std::ffi::CString::new(js).map_err(|e| e.to_string())?;

    webview
        .with_webview(move |pw| {
            let wk = pw.inner() as *mut Object;
            if wk.is_null() {
                let _ = tx.send(Err("null webview handle".into()));
                return;
            }
            let tx_block = tx.clone();
            let completion = ConcreteBlock::new(move |result: *mut Object, error: *mut Object| {
                let out = if !error.is_null() {
                    Err("page script failed".to_string())
                } else if result.is_null() {
                    Err("page returned no result".to_string())
                } else {
                    unsafe { nsstring_to_string(result) }
                        .ok_or_else(|| "page returned a non-string result".to_string())
                };
                let _ = tx_block.send(out);
            });
            let completion = completion.copy();
            unsafe {
                let ns_js: *mut Object =
                    msg_send![class!(NSString), stringWithUTF8String: js.as_ptr()];
                let _: () = msg_send![
                    wk,
                    evaluateJavaScript: ns_js
                    completionHandler: &*completion
                ];
            }
        })
        .map_err(|e| e.to_string())?;

    match rx.recv_timeout(Duration::from_secs(6)) {
        Ok(result) => result,
        Err(_) => Err("page read timed out".into()),
    }
}

#[cfg(not(target_os = "macos"))]
pub(super) fn eval_with_result(_webview: &tauri::Webview, _js: &str) -> Result<String, String> {
    Err("browser_read_active is only supported on macOS".into())
}

// Apply (or clear) native content blocking on one content webview via WebKit's
// WKContentRuleListStore — Safari's own content-blocker engine. When enabling,
// compile the curated blocklist (the store caches the compiled result on disk by
// identifier, so this is fast after the first tab) and add it to the webview's
// user-content controller; when disabling, drop all rule lists. Rule-list changes
// take effect on the next resource load, so a live page reflects a toggle on
// reload. Fire-and-forget: compilation completes on the main thread after this
// (worker-thread) call returns.
#[cfg(target_os = "macos")]
pub(super) fn apply_content_blocking(webview: &tauri::Webview, enabled: bool) {
    use block::ConcreteBlock;
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    let ident = match std::ffi::CString::new(BLOCKLIST_ID) {
        Ok(c) => c,
        Err(_) => return,
    };
    let json = std::ffi::CString::new(BLOCKLIST_JSON).ok();

    let _ = webview.with_webview(move |pw| {
        let wk = pw.inner() as *mut Object;
        if wk.is_null() {
            return;
        }
        unsafe {
            let config: *mut Object = msg_send![wk, configuration];
            let ucc: *mut Object = msg_send![config, userContentController];
            if ucc.is_null() {
                return;
            }
            if !enabled {
                let _: () = msg_send![ucc, removeAllContentRuleLists];
                return;
            }
            let Some(json) = json else { return };
            let store: *mut Object = msg_send![class!(WKContentRuleListStore), defaultStore];
            if store.is_null() {
                return;
            }
            let ns_id: *mut Object =
                msg_send![class!(NSString), stringWithUTF8String: ident.as_ptr()];
            let ns_json: *mut Object =
                msg_send![class!(NSString), stringWithUTF8String: json.as_ptr()];
            // The completion fires (async) on the main thread; capture the
            // controller by address (raw pointers aren't Send) and retain it so a
            // tab closed mid-compile can't free it out from under the add. WebKit
            // guarantees the completion runs, so the paired release always fires.
            let _: *mut Object = msg_send![ucc, retain];
            let ucc_addr = ucc as usize;
            let completion = ConcreteBlock::new(move |list: *mut Object, err: *mut Object| {
                let ucc = ucc_addr as *mut Object;
                if err.is_null() && !list.is_null() {
                    let _: () = msg_send![ucc, addContentRuleList: list];
                }
                let _: () = msg_send![ucc, release];
            });
            let completion = completion.copy();
            let _: () = msg_send![store,
                compileContentRuleListForIdentifier: ns_id
                encodedContentRuleList: ns_json
                completionHandler: &*completion];
        }
    });
}

#[cfg(not(target_os = "macos"))]
pub(super) fn apply_content_blocking(_webview: &tauri::Webview, _enabled: bool) {}

// Read a content webview's page title. macOS reads WKWebView's `title` property
// on the main thread (mirrors the screenshot snapshot bridge).
#[cfg(target_os = "macos")]
pub(super) fn webview_title(webview: &tauri::Webview) -> Option<String> {
    use objc::runtime::Object;
    use objc::{msg_send, sel, sel_impl};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    let (tx, rx) = channel::<Option<String>>();
    webview
        .with_webview(move |pw| {
            let wk = pw.inner() as *mut Object;
            let title = if wk.is_null() {
                None
            } else {
                unsafe {
                    let ns: *mut Object = msg_send![wk, title];
                    nsstring_to_string(ns)
                }
            };
            let _ = tx.send(title);
        })
        .ok()?;

    rx.recv_timeout(Duration::from_secs(2)).ok().flatten()
}

#[cfg(target_os = "macos")]
pub(super) unsafe fn nsstring_to_string(s: *mut objc::runtime::Object) -> Option<String> {
    use objc::{msg_send, sel, sel_impl};

    if s.is_null() {
        return None;
    }
    let utf8: *const std::os::raw::c_char = msg_send![s, UTF8String];
    if utf8.is_null() {
        return None;
    }
    std::ffi::CStr::from_ptr(utf8)
        .to_str()
        .ok()
        .map(|s| s.to_string())
}

#[cfg(not(target_os = "macos"))]
pub(super) fn webview_title(_webview: &tauri::Webview) -> Option<String> {
    None
}

// WKWebView snapshot is async (completion handler); bridge it back to this
// (worker-thread) command over a channel. `with_webview` runs the closure on the
// main thread, which is free to fire the completion while we block on `recv`.
#[cfg(target_os = "macos")]
// Same threading contract as `eval_with_result`: the caller must be an async
// command — a sync (main-thread) caller blocks the run loop that must deliver
// the snapshot completion, and every capture times out.
pub(super) fn capture_webview(webview: &tauri::Webview) -> Result<Vec<u8>, String> {
    use block::ConcreteBlock;
    use objc::runtime::Object;
    use objc::{msg_send, sel, sel_impl};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    let (tx, rx) = channel::<Result<Vec<u8>, String>>();

    webview
        .with_webview(move |pw| {
            let wk = pw.inner() as *mut Object;
            if wk.is_null() {
                let _ = tx.send(Err("null webview handle".into()));
                return;
            }

            let tx_block = tx.clone();
            let completion = ConcreteBlock::new(move |image: *mut Object, _err: *mut Object| {
                let result = if image.is_null() {
                    Err("snapshot returned nil".to_string())
                } else {
                    unsafe { nsimage_to_png(image) }
                };
                let _ = tx_block.send(result);
            });
            // Move the block to the heap; WKWebView copies/retains it for the
            // duration of the async call, so it outlives this closure.
            let completion = completion.copy();

            unsafe {
                let nil: *mut Object = std::ptr::null_mut();
                let _: () = msg_send![
                    wk,
                    takeSnapshotWithConfiguration: nil
                    completionHandler: &*completion
                ];
            }
        })
        .map_err(|e| e.to_string())?;

    match rx.recv_timeout(Duration::from_secs(8)) {
        Ok(result) => result,
        Err(_) => Err("screenshot timed out".into()),
    }
}

#[cfg(target_os = "macos")]
unsafe fn nsimage_to_png(image: *mut objc::runtime::Object) -> Result<Vec<u8>, String> {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    let tiff: *mut Object = msg_send![image, TIFFRepresentation];
    if tiff.is_null() {
        return Err("no TIFF representation".into());
    }
    let rep: *mut Object = msg_send![class!(NSBitmapImageRep), imageRepWithData: tiff];
    if rep.is_null() {
        return Err("no bitmap representation".into());
    }
    let props: *mut Object = msg_send![class!(NSDictionary), dictionary];
    // NSBitmapImageFileType.png == 4
    let png: *mut Object = msg_send![rep, representationUsingType: 4u64 properties: props];
    if png.is_null() {
        return Err("PNG encoding failed".into());
    }
    let len: usize = msg_send![png, length];
    let bytes: *const u8 = msg_send![png, bytes];
    if bytes.is_null() || len == 0 {
        return Err("empty PNG data".into());
    }
    Ok(std::slice::from_raw_parts(bytes, len).to_vec())
}

#[cfg(not(target_os = "macos"))]
pub(super) fn capture_webview(_webview: &tauri::Webview) -> Result<Vec<u8>, String> {
    Err("browser_screenshot is only supported on macOS".into())
}
