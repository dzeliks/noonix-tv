// how much a stream may ask of this pc and its internet. setup recommends a level from the speed
// check; the ranking puts anything above it at the bottom with a warning (it may stutter here)
use crate::store;
use crate::stremio::Stream;
use serde_json::{json, Value};

pub struct Level {
    pub id: &'static str,
    pub max_res: u32,
    pub remux: bool,
    /// average bitrate cap, mbit/s
    pub max_mbps: Option<f64>,
    /// what the speed check should show for it to play smoothly (peaks run ~2x the average)
    pub net: f64,
    /// software 4k hevc 10-bit fps (bench.rs): a film needs 24, a remux's bits cost more on top
    pub device: u32,
}

pub const LEVELS: &[Level] = &[
    Level { id: "light", max_res: 1080, remux: false, max_mbps: Some(8.0), net: 0.0, device: 0 },
    Level { id: "hd", max_res: 1080, remux: false, max_mbps: Some(20.0), net: 25.0, device: 8 },
    Level { id: "4k", max_res: 2160, remux: false, max_mbps: Some(35.0), net: 50.0, device: 24 },
    Level { id: "max", max_res: 2160, remux: true, max_mbps: None, net: 120.0, device: 36 },
];

/// installs from before the levels keep what they had: everything
pub const DEFAULT: &str = "max";

pub fn level(id: &str) -> &'static Level {
    LEVELS.iter().find(|l| l.id == id).unwrap_or_else(|| level(DEFAULT))
}

/// the highest level both measurements allow; one not measured doesn't hold it back,
/// except that nothing measured at all stays at 4k (a remux on an unknown line is a gamble)
pub fn recommend(mbps: Option<f64>, device: Option<u32>) -> &'static str {
    let fits = |l: &Level| mbps.is_none_or(|m| m >= l.net) && device.is_none_or(|d| d >= l.device);
    let best = LEVELS.iter().rev().find(|l| fits(l)).map_or("light", |l| l.id);
    if mbps.is_none() && device.is_none() && best == "max" { "4k" } else { best }
}

pub async fn current() -> &'static Level {
    let v = store::with(|c| store::get_setting(c, "app", "quality")).await.ok().flatten();
    level(v.as_ref().and_then(Value::as_str).unwrap_or(DEFAULT))
}

/// above the level: too sharp, a remux it leaves out, or more bits per second than it allows
pub fn over(s: &Stream, l: &Level, runtime_min: Option<f64>) -> bool {
    if s.resolution > l.max_res {
        return true;
    }
    if !l.remux && s.source.as_deref() == Some("Remux") {
        return true;
    }
    match (l.max_mbps, s.size) {
        (Some(cap), Some(size)) => {
            let mins = runtime_min.unwrap_or(if s.resolution >= 2160 { 120.0 } else { 50.0 });
            size as f64 * 8.0 / (mins * 60.0) / 1e6 > cap
        }
        _ => false,
    }
}

/// what setup and settings show: the choice, the recommendation and why the ones above it may not play well
pub async fn options() -> Value {
    let (net, dev, cur) = store::with(|c| {
        // bench_decode: 4k hdr fps. the old bench_device (sha-256 points) is left alone
        Ok((store::get_setting(c, "app", "bench_net")?, store::get_setting(c, "app", "bench_decode")?, store::get_setting(c, "app", "quality")?))
    })
    .await
    .unwrap_or((None, None, None));
    let mbps = net.as_ref().and_then(Value::as_f64);
    let device = dev.as_ref().and_then(Value::as_u64).map(|d| d as u32);
    let rec = recommend(mbps, device);
    let levels: Vec<Value> = LEVELS
        .iter()
        .map(|l| {
            json!({
                "id": l.id,
                "needMbps": l.net,
                "needDevice": l.device,
                "netOk": mbps.is_none_or(|m| m >= l.net),
                "deviceOk": device.is_none_or(|d| d >= l.device),
            })
        })
        .collect();
    json!({
        "current": level(cur.as_ref().and_then(Value::as_str).unwrap_or(DEFAULT)).id,
        "chosen": cur.is_some(),
        "recommended": rec,
        "mbps": mbps,
        "device": device,
        "levels": levels,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recommendation() {
        assert_eq!(recommend(Some(300.0), Some(100)), "max");
        assert_eq!(recommend(Some(300.0), Some(30)), "4k");
        assert_eq!(recommend(Some(300.0), Some(62)), "max");
        assert_eq!(recommend(Some(300.0), Some(20)), "hd");
        assert_eq!(recommend(Some(60.0), Some(100)), "4k");
        assert_eq!(recommend(Some(30.0), None), "hd");
        assert_eq!(recommend(Some(10.0), Some(100)), "light");
        assert_eq!(recommend(None, Some(5)), "light");
        assert_eq!(recommend(None, None), "4k");
        assert_eq!(recommend(None, Some(100)), "max");
    }

    #[test]
    fn above_the_level() {
        let mut s = crate::stremio::parse_release("Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.Atmos.7.1-GRP");
        s.size = Some(70_000_000_000);
        assert!(over(&s, level("hd"), Some(120.0)));
        assert!(over(&s, level("4k"), Some(120.0)));
        assert!(!over(&s, level("max"), Some(120.0)));
        let mut web = crate::stremio::parse_release("Show.S01E01.2160p.WEB-DL.DDP5.1.HDR.HEVC-GRP");
        web.size = Some(8_000_000_000);
        assert!(!over(&web, level("4k"), Some(55.0)));
        assert!(over(&web, level("light"), Some(55.0)));
        // a level never filters what it can't measure
        web.size = None;
        web.resolution = 1080;
        assert!(!over(&web, level("light"), None));
    }
}
