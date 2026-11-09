//! the core for clients that aren't qt (the native macos app): a c interface over rpc::dispatch,
//! the same calls and pushes the qml singleton (bridge.rs) carries. strings are utf-8 json; every
//! string handed out is owned by the core and only valid during the callback
use crate::{app, rpc};
use once_cell::sync::OnceCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::atomic::{AtomicU64, Ordering};

/// answer to a call: (ctx, id, ok, json)
pub type ResultFn = extern "C" fn(*mut c_void, u64, bool, *const c_char);
/// a push from the core: (ctx, name, json)
pub type PushFn = extern "C" fn(*mut c_void, *const c_char, *const c_char);

struct Client {
    ctx: usize,
    on_result: ResultFn,
    on_push: PushFn,
}

static CLIENT: OnceCell<Client> = OnceCell::new();
static NEXT: AtomicU64 = AtomicU64::new(1);

fn text(s: String) -> CString {
    CString::new(s).unwrap_or_default()
}

/// starts the core once: logging, secrets, pushes, the in-app keepalive. the callbacks run on the
/// core's threads, the client hops to its own
#[no_mangle]
pub extern "C" fn noonix_start(ctx: *mut c_void, on_result: ResultFn, on_push: PushFn) -> bool {
    let fresh = CLIENT.set(Client { ctx: ctx as usize, on_result, on_push }).is_ok();
    if !fresh {
        return false;
    }
    app::init_app_logging();
    crate::config::init_secrets();
    if let Some(mut rx) = app::event_channel() {
        app::RUNTIME.spawn(async move {
            while let Some((name, payload)) = rx.recv().await {
                if let Some(c) = CLIENT.get() {
                    let (name, json) = (text(name), text(payload.to_string()));
                    (c.on_push)(c.ctx as *mut c_void, name.as_ptr(), json.as_ptr());
                }
            }
        });
    }
    app::RUNTIME.spawn(crate::keepalive::in_app());
    app::RUNTIME.spawn(crate::tvserver::apply());
    tracing::info!("core up (c interface)");
    true
}

/// one rpc call; the answer comes to on_result with the id returned here
#[no_mangle]
pub extern "C" fn noonix_call(method: *const c_char, args: *const c_char) -> u64 {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    // safety: the caller passes nul-terminated utf-8 (or null for no arguments)
    let method = if method.is_null() { String::new() } else { unsafe { CStr::from_ptr(method) }.to_string_lossy().into_owned() };
    let args = if args.is_null() {
        serde_json::Value::Null
    } else {
        serde_json::from_str(&unsafe { CStr::from_ptr(args) }.to_string_lossy()).unwrap_or(serde_json::Value::Null)
    };
    app::RUNTIME.spawn(async move {
        let (ok, json) = match rpc::dispatch(&method, args).await {
            Ok(v) => (true, v.to_string()),
            Err(e) => {
                tracing::warn!("{method}: {e:#}");
                (false, serde_json::json!({ "error": format!("{e:#}") }).to_string())
            }
        };
        if let Some(c) = CLIENT.get() {
            let json = text(json);
            (c.on_result)(c.ctx as *mut c_void, id, ok, json.as_ptr());
        }
    });
    id
}
