pub mod addons;
pub mod app;
pub mod bench;
#[cfg(feature = "qt")]
pub mod bridge;
pub mod config;
#[cfg(unix)]
pub mod desktop;
#[cfg(windows)]
#[path = "desktop_win.rs"]
pub mod desktop;
pub mod extensions;
#[cfg(not(feature = "qt"))]
pub mod ffi;
pub mod home;
pub mod http;
pub mod keepalive;
pub mod library;
pub mod local;
pub mod matches;
pub mod playback;
pub mod probe;
pub mod quality;
pub mod ranking;
pub mod rpc;
pub mod setup;
pub mod skip;
pub mod store;
pub mod subtitles;
pub mod stremio;
pub mod system;
pub mod tmdb;
pub mod torrent;
pub mod trakt;
pub mod update;
#[cfg(windows)]
mod winjob;
