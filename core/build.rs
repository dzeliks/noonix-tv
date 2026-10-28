fn main() {
    // the app's own tmdb key and trakt client id are compiled in, one for everyone (config.rs
    // option_env!). a release build (NOONIX_RELEASE=1, ci) without them fails: it would ship an app
    // with an empty home. a local build only warns (tools/install-local.sh fills them in)
    println!("cargo:rerun-if-env-changed=NOONIX_RELEASE");
    // the repo the updater follows (update.rs), the one ci builds in
    println!("cargo:rerun-if-env-changed=NOONIX_UPDATE_REPO");
    for key in ["NOONIX_TMDB_API_KEY", "NOONIX_TRAKT_CLIENT_ID"] {
        println!("cargo:rerun-if-env-changed={key}");
        if std::env::var(key).map_or(true, |v| v.trim().is_empty()) {
            if std::env::var_os("NOONIX_RELEASE").is_some_and(|v| v == "1") {
                panic!("{key} is not set: a release must have the built-in app keys");
            }
            println!("cargo:warning={key} is not set: this build has no built-in key");
        }
    }

    #[cfg(feature = "qt")]
    {
        use cxx_qt_build::{CxxQtBuilder, QmlModule};
        CxxQtBuilder::new_qml_module(QmlModule::new("Noonix.Core"))
            .qt_module("Qml")
            .files(["src/bridge.rs"])
            .build();
    }
}
