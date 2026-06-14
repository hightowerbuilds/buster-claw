//! Embedded browser: a child webview hosted inside the main window, positioned
//! over a placeholder element in the `/browse` LiveView. Unlike an `<iframe>`,
//! a real child webview ignores `X-Frame-Options`, so it can load any HTTPS site.
//!
//! The webview is created on demand at a bounding rect (logical px, relative to
//! the main webview's viewport) and re-positioned by the JS hook as the layout
//! changes. It is **not** listed in any capability, so the pages it loads have no
//! access to Tauri commands — external content stays sandboxed from the app.

use tauri::webview::WebviewBuilder;
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, Url, WebviewUrl};

const LABEL: &str = "embedded-browser";

/// Open (or, if already open, navigate + reposition) the embedded browser at the
/// given bounds, loading `url`.
#[tauri::command]
pub fn browser_open(
    app: AppHandle,
    url: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    if let Some(webview) = app.get_webview(LABEL) {
        webview
            .set_position(LogicalPosition::new(x, y))
            .map_err(|e| e.to_string())?;
        webview
            .set_size(LogicalSize::new(width, height))
            .map_err(|e| e.to_string())?;
        return navigate(app, url);
    }

    let window = app
        .get_window("main")
        .ok_or_else(|| "main window missing".to_string())?;
    let parsed: Url = url.parse().map_err(|e| format!("invalid url: {e}"))?;

    window
        .add_child(
            WebviewBuilder::new(LABEL, WebviewUrl::External(parsed)),
            LogicalPosition::new(x, y),
            LogicalSize::new(width, height),
        )
        .map_err(|e| format!("failed to create embedded browser: {e}"))?;

    Ok(())
}

/// Move/resize the embedded browser to track the placeholder element.
#[tauri::command]
pub fn browser_set_bounds(
    app: AppHandle,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let Some(webview) = app.get_webview(LABEL) else {
        return Ok(());
    };
    webview
        .set_position(LogicalPosition::new(x, y))
        .map_err(|e| e.to_string())?;
    webview
        .set_size(LogicalSize::new(width, height))
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn browser_navigate(app: AppHandle, url: String) -> Result<(), String> {
    navigate(app, url)
}

#[tauri::command]
pub fn browser_back(app: AppHandle) -> Result<(), String> {
    eval(app, "history.back()")
}

#[tauri::command]
pub fn browser_forward(app: AppHandle) -> Result<(), String> {
    eval(app, "history.forward()")
}

#[tauri::command]
pub fn browser_reload(app: AppHandle) -> Result<(), String> {
    eval(app, "location.reload()")
}

/// Tear down the embedded browser (called when leaving `/browse`).
#[tauri::command]
pub fn browser_close(app: AppHandle) -> Result<(), String> {
    if let Some(webview) = app.get_webview(LABEL) {
        webview.close().map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn navigate(app: AppHandle, url: String) -> Result<(), String> {
    let Some(webview) = app.get_webview(LABEL) else {
        return Ok(());
    };
    let parsed: Url = url.parse().map_err(|e| format!("invalid url: {e}"))?;
    webview.navigate(parsed).map_err(|e| e.to_string())
}

fn eval(app: AppHandle, js: &str) -> Result<(), String> {
    let Some(webview) = app.get_webview(LABEL) else {
        return Ok(());
    };
    webview.eval(js).map_err(|e| e.to_string())
}
