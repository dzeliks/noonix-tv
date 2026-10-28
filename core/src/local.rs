// sources a build brings along on this pc. the public app has none: what plays comes from the
// library and from what the user adds. a build of its own can fill these in
use serde_json::{json, Value};

/// at launch, in the background
pub fn start() {}

/// until whatever start() began answers
pub async fn wait() {}

/// languages, profile, quality or a key changed: anything built in follows
pub fn changed(_why: &'static str) {}

/// before an addon of this build is asked for streams
pub async fn ready(_manifest_url: &str) {}

/// the debrid services and torrents those sources need, like an extension's (none here)
pub fn wants() -> (Vec<&'static str>, bool) {
    (Vec::new(), false)
}

pub async fn status() -> Value {
    json!({ "builtin": false })
}

pub async fn stop() {}
