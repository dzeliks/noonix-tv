#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qml_singleton]
        type Core = super::CoreRust;

        // answer comes back as result(id, ok, json)
        #[qinvokable]
        fn call(self: Pin<&mut Self>, method: &QString, args: &QString) -> u64;

        #[qsignal]
        fn result(self: Pin<&mut Self>, id: u64, ok: bool, json: QString);

        #[qsignal]
        fn push(self: Pin<&mut Self>, name: QString, json: QString);
    }

    impl cxx_qt::Threading for Core {}
    impl cxx_qt::Initialize for Core {}
}

use crate::{app, rpc};
use core::pin::Pin;
use cxx_qt::{CxxQtType, Threading};
use cxx_qt_lib::QString;
use serde_json::Value;

#[derive(Default)]
pub struct CoreRust {
    next_id: u64,
}

impl cxx_qt::Initialize for qobject::Core {
    fn initialize(self: Pin<&mut Self>) {
        app::init_app_logging();
        crate::config::init_secrets();
        if let Some(mut rx) = app::event_channel() {
            let qt = self.qt_thread();
            app::RUNTIME.spawn(async move {
                while let Some((name, payload)) = rx.recv().await {
                    let json = payload.to_string();
                    if qt
                        .queue(move |obj| obj.push(QString::from(&name), QString::from(&json)))
                        .is_err()
                    {
                        break; // ui gone
                    }
                }
            });
        }
        app::RUNTIME.spawn_blocking(crate::desktop::refresh);
        // logins stay alive while the app is open, timer or not
        app::RUNTIME.spawn(crate::keepalive::in_app());
        tracing::info!("core up");
    }
}

impl qobject::Core {
    pub fn call(mut self: Pin<&mut Self>, method: &QString, args: &QString) -> u64 {
        let id = {
            let mut rust = self.as_mut().rust_mut();
            rust.next_id += 1;
            rust.next_id
        };
        let method = method.to_string();
        let args: Value = serde_json::from_str(&args.to_string()).unwrap_or(Value::Null);
        let qt = self.qt_thread();
        app::RUNTIME.spawn(async move {
            let (ok, json) = match rpc::dispatch(&method, args).await {
                Ok(v) => (true, v.to_string()),
                Err(e) => {
                    tracing::warn!("{method}: {e:#}");
                    (false, serde_json::json!({ "error": format!("{e:#}") }).to_string())
                }
            };
            let _ = qt.queue(move |obj| obj.result(id, ok, QString::from(&json)));
        });
        id
    }
}
