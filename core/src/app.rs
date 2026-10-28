use once_cell::sync::{Lazy, OnceCell};
use serde_json::Value;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

// small on purpose, everything here is io bound
pub static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(3)
        .thread_name("noonix-core")
        .enable_all()
        .build()
        .expect("tokio runtime")
});

static EVENTS: OnceCell<mpsc::UnboundedSender<(String, Value)>> = OnceCell::new();

pub fn emit(name: &str, payload: Value) {
    if let Some(tx) = EVENTS.get() {
        let _ = tx.send((name.to_owned(), payload));
    }
}

pub(crate) fn event_channel() -> Option<mpsc::UnboundedReceiver<(String, Value)>> {
    let (tx, rx) = mpsc::unbounded_channel();
    EVENTS.set(tx).ok().map(|_| rx)
}

pub fn init_logging() {
    use tracing_subscriber::{fmt, EnvFilter};
    let filter = EnvFilter::try_from_env("NOONIX_LOG").unwrap_or_else(|_| EnvFilter::new("noonix_core=info"));
    let _ = fmt().with_env_filter(filter).with_target(false).with_writer(std::io::stderr).try_init();
}

/// the app: stderr and ~/.local/state/noonix-tv/noonix-tv.log (launchers like the remote daemon drop
/// stderr). one old log is kept as .log.1
pub fn init_app_logging() {
    use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, Layer};
    let filter = || EnvFilter::try_from_env("NOONIX_LOG").unwrap_or_else(|_| EnvFilter::new("noonix_core=info"));
    let dir = &crate::config::PATHS.state;
    let path = dir.join("noonix-tv.log");
    let _ = std::fs::create_dir_all(dir);
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > 0) {
        let _ = std::fs::rename(&path, dir.join("noonix-tv.log.1"));
    }
    let file = std::fs::OpenOptions::new().create(true).append(true).open(&path).ok().map(std::sync::Arc::new);
    let stderr = fmt::layer().with_target(false).with_writer(std::io::stderr).with_filter(filter());
    let file = file.map(|f| fmt::layer().with_target(false).with_ansi(false).with_writer(f).with_filter(filter()));
    let _ = tracing_subscriber::registry().with(stderr).with(file).try_init();
}
