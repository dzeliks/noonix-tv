// setup's benchmark: internet speed and how fast this pc is. only a score for now, nothing
// acts on it yet
use crate::http::CLIENT;
use anyhow::{Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};

// cloudflare's speed test answers any size from the nearest edge
const DOWN: &str = "https://speed.cloudflare.com/__down?bytes=25000000";
const NET_FOR: Duration = Duration::from_secs(6);
const CPU_FOR: Duration = Duration::from_millis(1500);

/// a 4k remux wants ~80 mbit/s: that's 80 points, more is a bonus up to 100
pub fn net_score(mbps: f64) -> u32 {
    mbps.clamp(0.0, 100.0).round() as u32
}

/// sha-256 throughput of all cores (release build); this pc's 16 threads, ~2100 mb/s, are 100
pub fn device_score(mb_per_s: f64) -> u32 {
    (mb_per_s / 21.0).round().max(1.0) as u32
}

pub async fn internet() -> Result<Value> {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;
    // one answer is capped below 100 mb: a few parallel 25 mb downloads, again and again
    let got = Arc::new(AtomicU64::new(0));
    let start = Instant::now();
    let workers: Vec<_> = (0..4)
        .map(|_| {
            let got = got.clone();
            tokio::spawn(async move {
                while start.elapsed() < NET_FOR {
                    let mut res = CLIENT.get(DOWN).timeout(NET_FOR + Duration::from_secs(5)).send().await?.error_for_status()?;
                    while let Some(c) = res.chunk().await? {
                        got.fetch_add(c.len() as u64, Ordering::Relaxed);
                        if start.elapsed() >= NET_FOR {
                            break;
                        }
                    }
                }
                anyhow::Ok(())
            })
        })
        .collect();
    // the first second is tcp warming up: measure after it
    tokio::time::sleep(Duration::from_secs(1)).await;
    let (from, from_bytes) = (Instant::now(), got.load(Ordering::Relaxed));
    // the gauge follows along
    while !workers.iter().all(|w| w.is_finished()) {
        tokio::time::sleep(Duration::from_millis(250)).await;
        let bytes = got.load(Ordering::Relaxed) - from_bytes;
        let mbps = bytes as f64 * 8.0 / from.elapsed().as_secs_f64().max(0.001) / 1e6;
        crate::app::emit("bench", json!({ "mbps": mbps.round() }));
    }
    let mut errors = Vec::new();
    for w in workers {
        if let Ok(Err(e)) = w.await {
            errors.push(e);
        }
    }
    let bytes = got.load(Ordering::Relaxed) - from_bytes;
    if bytes == 0 {
        return Err(errors.pop().unwrap_or_else(|| anyhow::anyhow!("no data"))).context("couldn't reach the speed test");
    }
    let mbps = bytes as f64 * 8.0 / from.elapsed().as_secs_f64().max(0.001) / 1e6;
    Ok(json!({ "mbps": mbps.round(), "score": net_score(mbps) }))
}

pub async fn device() -> Result<Value> {
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    let total = tokio::task::spawn_blocking(move || {
        let block = vec![0x5au8; 1 << 20];
        let workers: Vec<_> = (0..threads)
            .map(|_| {
                let block = block.clone();
                std::thread::spawn(move || {
                    let start = Instant::now();
                    let mut n = 0u64;
                    let mut h = Sha256::new();
                    while start.elapsed() < CPU_FOR {
                        h.update(&block);
                        n += 1;
                    }
                    std::hint::black_box(h.finalize());
                    n as f64 / start.elapsed().as_secs_f64()
                })
            })
            .collect();
        workers.into_iter().map(|w| w.join().unwrap_or(0.0)).sum::<f64>()
    })
    .await?;
    Ok(json!({ "threads": threads, "mbPerS": total.round(), "score": device_score(total) }))
}

#[cfg(test)]
mod tests {
    #[test]
    fn scores() {
        assert_eq!(super::net_score(0.0), 0);
        assert_eq!(super::net_score(80.4), 80);
        assert_eq!(super::net_score(940.0), 100);
        assert_eq!(super::device_score(2100.0), 100);
        assert_eq!(super::device_score(5.0), 1);
    }
}
