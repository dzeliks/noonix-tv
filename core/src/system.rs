// tv integration: refresh rate matching, dualsense leds, playback state file
use anyhow::Result;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;

pub fn has_command(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(name).is_file()))
        .unwrap_or(false)
}

#[derive(Debug, Clone)]
pub struct ModeSwitch {
    pub output: String,
    pub original: String,
}

/// standard tv rates; 23.976 etc are listed by kscreen as 23.97599...
const RATES: &[f64] = &[23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0];

/// picks the refresh rate for this fps at the output's CURRENT resolution (never touches
/// resolution or hdr). returns the switch to undo later and whether the match is exact
pub async fn match_refresh(output: &str, fps: f64) -> Result<(Option<ModeSwitch>, bool)> {
    if fps <= 1.0 {
        return Ok((None, false));
    }
    let target = RATES
        .iter()
        .copied()
        .filter(|r| ((r - fps) / fps).abs() < 0.01)
        .min_by(|a, b| (a - fps).abs().total_cmp(&(b - fps).abs()));
    let Some(target) = target else { return Ok((None, false)) };
    let (cur_id, modes) = display::modes(output).await?;
    let best = modes
        .into_iter()
        .filter(|(_, hz)| (hz - target).abs() < 0.02)
        .min_by(|a, b| (a.1 - target).abs().total_cmp(&(b.1 - target).abs()));
    let Some((mode, hz)) = best else { return Ok((None, false)) };
    let exact = ((hz - fps) / fps).abs() < 0.0005;
    if mode == cur_id {
        return Ok((None, exact));
    }
    tracing::info!("refresh {output}: {fps:.3} fps -> {hz:.3} Hz (mode {mode})");
    display::set_mode(output, &mode).await?;
    // the tv takes a moment to resync; check it really switched
    tokio::time::sleep(Duration::from_millis(1800)).await;
    if display::modes(output).await?.0 != mode {
        tracing::warn!("refresh switch didn't stick");
        return Ok((None, false));
    }
    Ok((Some(ModeSwitch { output: output.to_owned(), original: cur_id }), exact))
}

pub async fn restore_refresh(sw: &ModeSwitch) {
    if let Err(e) = display::restore(&sw.output, &sw.original).await {
        tracing::warn!("refresh restore: {e:#}");
    }
}

// kscreen-doctor on plasma
#[cfg(all(unix, not(target_os = "macos")))]
mod display {
    use anyhow::{Context, Result};
    use serde_json::Value;
    use tokio::process::Command;

    async fn kscreen() -> Result<Value> {
        let out = Command::new("kscreen-doctor").arg("-j").output().await.context("kscreen-doctor")?;
        serde_json::from_slice(&out.stdout).context("kscreen-doctor json")
    }

    /// the current mode id and every mode at the current size as (id, hz)
    pub async fn modes(output: &str) -> Result<(String, Vec<(String, f64)>)> {
        let v = kscreen().await?;
        let o = v
            .get("outputs")
            .and_then(Value::as_array)
            .and_then(|a| a.iter().find(|o| o.get("name").and_then(Value::as_str) == Some(output)))
            .with_context(|| format!("no output {output}"))?;
        let modes = o.get("modes").and_then(Value::as_array).context("modes")?;
        let cur_id = o.get("currentModeId").and_then(Value::as_str).context("current mode")?.to_owned();
        let cur = modes.iter().find(|m| m.get("id").and_then(Value::as_str) == Some(&cur_id)).context("current mode")?;
        let size = cur.get("size").cloned();
        let list = modes
            .iter()
            .filter(|m| m.get("size").cloned() == size)
            .filter_map(|m| Some((m.get("id")?.as_str()?.to_owned(), m.get("refreshRate")?.as_f64()?)))
            .collect();
        Ok((cur_id, list))
    }

    pub async fn set_mode(output: &str, mode: &str) -> Result<()> {
        let st = Command::new("kscreen-doctor").arg(format!("output.{output}.mode.{mode}")).status().await?;
        anyhow::ensure!(st.success(), "kscreen-doctor failed");
        Ok(())
    }

    pub async fn restore(output: &str, mode: &str) -> Result<()> {
        set_mode(output, mode).await
    }
}

// coregraphics on macos; the output is the CGDirectDisplayID as text, a mode its io mode id.
// only modes of the same size in points and pixels count (never the resolution or hidpi)
#[cfg(target_os = "macos")]
mod display {
    use anyhow::{bail, Context, Result};
    use std::ffi::c_void;

    type Mode = *mut c_void;
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGDisplayCopyAllDisplayModes(display: u32, options: *const c_void) -> *const c_void;
        fn CGDisplayCopyDisplayMode(display: u32) -> Mode;
        fn CGDisplayModeGetWidth(mode: Mode) -> usize;
        fn CGDisplayModeGetHeight(mode: Mode) -> usize;
        fn CGDisplayModeGetPixelWidth(mode: Mode) -> usize;
        fn CGDisplayModeGetPixelHeight(mode: Mode) -> usize;
        fn CGDisplayModeGetRefreshRate(mode: Mode) -> f64;
        fn CGDisplayModeGetIODisplayModeID(mode: Mode) -> i32;
        fn CGDisplayModeRelease(mode: Mode);
        fn CGDisplaySetDisplayMode(display: u32, mode: Mode, options: *const c_void) -> i32;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFArrayGetCount(array: *const c_void) -> isize;
        fn CFArrayGetValueAtIndex(array: *const c_void, i: isize) -> *const c_void;
        fn CFRelease(cf: *const c_void);
    }

    fn size(m: Mode) -> [usize; 4] {
        unsafe { [CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m), CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m)] }
    }

    /// the current mode and every mode at its size, as (io mode id, hz, the mode)
    fn with_modes<T>(output: &str, f: impl FnOnce(i32, Vec<(i32, f64, Mode)>) -> T) -> Result<T> {
        let display: u32 = output.parse().context("display id")?;
        unsafe {
            let cur = CGDisplayCopyDisplayMode(display);
            if cur.is_null() {
                bail!("no display {output}");
            }
            let all = CGDisplayCopyAllDisplayModes(display, std::ptr::null());
            let (cur_id, cur_size) = (CGDisplayModeGetIODisplayModeID(cur), size(cur));
            let mut list = Vec::new();
            if !all.is_null() {
                for i in 0..CFArrayGetCount(all) {
                    let m = CFArrayGetValueAtIndex(all, i) as Mode;
                    if size(m) == cur_size {
                        list.push((CGDisplayModeGetIODisplayModeID(m), CGDisplayModeGetRefreshRate(m), m));
                    }
                }
            }
            let out = f(cur_id, list);
            if !all.is_null() {
                CFRelease(all);
            }
            CGDisplayModeRelease(cur);
            Ok(out)
        }
    }

    pub async fn modes(output: &str) -> Result<(String, Vec<(String, f64)>)> {
        with_modes(output, |cur, list| (cur.to_string(), list.into_iter().map(|(id, hz, _)| (id.to_string(), hz)).collect()))
    }

    pub async fn set_mode(output: &str, mode: &str) -> Result<()> {
        let want: i32 = mode.parse().context("mode id")?;
        let display: u32 = output.parse().context("display id")?;
        let err = with_modes(output, |_, list| {
            list.iter().find(|(id, ..)| *id == want).map(|(.., m)| unsafe { CGDisplaySetDisplayMode(display, *m, std::ptr::null()) })
        })?;
        match err {
            Some(0) => Ok(()),
            Some(e) => bail!("CGDisplaySetDisplayMode {e}"),
            None => bail!("no mode {mode}"),
        }
    }

    pub async fn restore(output: &str, mode: &str) -> Result<()> {
        set_mode(output, mode).await
    }
}

// windows display settings; the output is qt's screen name (\\.\DISPLAY1). windows lists
// 23.976 / 59.94 as 23 / 59 Hz
#[cfg(windows)]
mod display {
    use anyhow::{bail, Result};
    use windows_sys::Win32::Graphics::Gdi::{
        ChangeDisplaySettingsExW, EnumDisplaySettingsW, CDS_FULLSCREEN, DEVMODEW, DISP_CHANGE_SUCCESSFUL, DM_DISPLAYFREQUENCY,
        ENUM_CURRENT_SETTINGS,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn mode_at(output: &[u16], n: u32) -> Option<DEVMODEW> {
        let mut dm: DEVMODEW = unsafe { std::mem::zeroed() };
        dm.dmSize = std::mem::size_of::<DEVMODEW>() as u16;
        (unsafe { EnumDisplaySettingsW(output.as_ptr(), n, &mut dm) } != 0).then_some(dm)
    }

    fn hz(dm: &DEVMODEW) -> f64 {
        let f = dm.dmDisplayFrequency;
        if matches!(f, 23 | 29 | 47 | 59 | 119) {
            (f + 1) as f64 / 1.001
        } else {
            f as f64
        }
    }

    fn all(output: &str) -> Result<(DEVMODEW, Vec<DEVMODEW>)> {
        let name = wide(output);
        let Some(cur) = mode_at(&name, ENUM_CURRENT_SETTINGS) else { bail!("no output {output}") };
        let list = (0..)
            .map_while(|n| mode_at(&name, n))
            .filter(|m| m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight && m.dmBitsPerPel == cur.dmBitsPerPel)
            .collect();
        Ok((cur, list))
    }

    pub async fn modes(output: &str) -> Result<(String, Vec<(String, f64)>)> {
        let (cur, list) = all(output)?;
        let mut out: Vec<(String, f64)> = list.iter().map(|m| (m.dmDisplayFrequency.to_string(), hz(m))).collect();
        out.dedup();
        Ok((cur.dmDisplayFrequency.to_string(), out))
    }

    pub async fn set_mode(output: &str, mode: &str) -> Result<()> {
        let (mut cur, _) = all(output)?;
        cur.dmDisplayFrequency = mode.parse()?;
        cur.dmFields = DM_DISPLAYFREQUENCY;
        // fullscreen = temporary: the saved mode comes back with restore() or a sign-out
        let r = unsafe { ChangeDisplaySettingsExW(wide(output).as_ptr(), &cur, std::ptr::null_mut(), CDS_FULLSCREEN, std::ptr::null()) };
        if r != DISP_CHANGE_SUCCESSFUL {
            bail!("windows refused {mode} Hz ({r})");
        }
        Ok(())
    }

    pub async fn restore(output: &str, _mode: &str) -> Result<()> {
        // no mode = back to the one saved in the registry
        let r = unsafe { ChangeDisplaySettingsExW(wide(output).as_ptr(), std::ptr::null(), std::ptr::null_mut(), 0, std::ptr::null()) };
        if r != DISP_CHANGE_SUCCESSFUL {
            bail!("windows refused the saved mode ({r})");
        }
        Ok(())
    }
}

/// lightbar off + dim player led while playing (this pc's dualsense-dim / dualsense-leds)
pub fn pads_dim(on: bool) {
    let cmd = if on { "dualsense-dim" } else { "dualsense-leds" };
    if has_command(cmd) {
        let _ = std::process::Command::new(cmd)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

/// $XDG_RUNTIME_DIR/noonix-tv/playback.json while something plays; the tv scripts
/// (screensaver holds, pad leds, idle-off) read it instead of hunting for an mpv process
pub fn state_path() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("noonix-tv/playback.json")
}

pub fn write_state(state: Option<Value>) {
    let p = state_path();
    match state {
        Some(mut v) => {
            v["pid"] = json!(std::process::id());
            if let Some(d) = p.parent() {
                let _ = std::fs::create_dir_all(d);
            }
            let tmp = p.with_extension("tmp");
            if std::fs::write(&tmp, v.to_string()).is_ok() {
                let _ = std::fs::rename(&tmp, &p);
            }
        }
        None => {
            let _ = std::fs::remove_file(&p);
        }
    }
}
