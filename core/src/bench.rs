// the speed check: internet speed and how fast this device is. quality.rs picks a level from both
use crate::http::CLIENT;
use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

static SKIP: AtomicBool = AtomicBool::new(false);

/// stops a running internet check (skip, or no connection worth waiting for)
pub fn skip_internet() {
    SKIP.store(true, Ordering::Relaxed);
}

// cloudflare's speed test answers any size from the nearest edge, but turns you away (429) after
// a few runs in a row: then the public test files of two hosters
const DOWNS: &[&str] = &[
    "https://speed.cloudflare.com/__down?bytes=25000000",
    "https://fsn1-speed.hetzner.com/100MB.bin",
    "https://proof.ovh.net/files/100Mb.dat",
];
const NET_FOR: Duration = Duration::from_secs(6);
const CPU_FOR: Duration = Duration::from_millis(2000);

/// a 4k remux wants ~80 mbit/s: that's 80 points, more is a bonus up to 100
pub fn net_score(mbps: f64) -> u32 {
    mbps.clamp(0.0, 100.0).round() as u32
}

/// blocks of the decode-shaped work below per 4k frame. calibrated on a 16 thread zen 3 that
/// software-decodes a 4k hevc main10 40 mbit/s clip at 62 fps with mpv
const BLOCKS_PER_FRAME: f64 = 80_000.0;

/// software 4k hevc 10-bit frames per second this device would decode
pub fn device_fps(blocks_per_s: f64) -> u32 {
    (blocks_per_s / BLOCKS_PER_FRAME).round().max(0.0) as u32
}

pub async fn internet() -> Result<Value> {
    SKIP.store(false, Ordering::Relaxed);
    let mut last = None;
    for url in DOWNS {
        if SKIP.load(Ordering::Relaxed) {
            anyhow::bail!("skipped");
        }
        match measure(url).await {
            Ok(mbps) => return Ok(json!({ "mbps": mbps.round(), "score": net_score(mbps) })),
            Err(e) => {
                tracing::warn!("bench.internet: {url}: {e:#}");
                last = Some(e);
            }
        }
    }
    Err(last.unwrap_or_else(|| anyhow::anyhow!("no data"))).context("couldn't reach the speed test")
}

async fn measure(url: &'static str) -> Result<f64> {
    // one answer is capped below 100 mb: a few parallel 25 mb downloads, again and again
    let got = Arc::new(AtomicU64::new(0));
    let start = Instant::now();
    let workers: Vec<_> = (0..4)
        .map(|_| {
            let got = got.clone();
            tokio::spawn(async move {
                while start.elapsed() < NET_FOR && !SKIP.load(Ordering::Relaxed) {
                    let mut res = CLIENT.get(url).timeout(NET_FOR + Duration::from_secs(5)).send().await?.error_for_status()?;
                    while let Some(c) = res.chunk().await? {
                        got.fetch_add(c.len() as u64, Ordering::Relaxed);
                        if start.elapsed() >= NET_FOR || SKIP.load(Ordering::Relaxed) {
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
    let abort = |workers: &[tokio::task::JoinHandle<Result<()>>]| workers.iter().for_each(|w| w.abort());
    if SKIP.load(Ordering::Relaxed) {
        abort(&workers);
        anyhow::bail!("skipped");
    }
    let (from, from_bytes) = (Instant::now(), got.load(Ordering::Relaxed));
    // the gauge follows along
    while !workers.iter().all(|w| w.is_finished()) {
        tokio::time::sleep(Duration::from_millis(250)).await;
        if SKIP.load(Ordering::Relaxed) {
            abort(&workers);
            anyhow::bail!("skipped");
        }
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
        return Err(errors.pop().unwrap_or_else(|| anyhow::anyhow!("no data")));
    }
    Ok(bytes as f64 * 8.0 / from.elapsed().as_secs_f64().max(0.001) / 1e6)
}

/// how much video this device decodes: software 4k hevc fps from work shaped like a decoder's
/// (serial arithmetic decoding, integer transforms, 8-tap 10-bit filtering), on every core. plain
/// scalar rust, the same work on every architecture (x86_64, arm64, windows, android, mac), no
/// special instructions, so cpus with hash or crypto units don't score better for it.
/// `hardware`: the client found a hevc main10 decoder, which is what actually carries 4k; it lifts
/// the score to the top level, `fps` stays what the cpu did
pub async fn device(hardware: bool) -> Result<Value> {
    // no core count (a sandbox, an odd kernel): a quad core, what most tv boxes and phones have
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let lift = move |fps: u32| if hardware { fps.max(crate::quality::top_device()) } else { fps };
    let rate = tokio::task::spawn_blocking(move || {
        let done = Arc::new(AtomicU64::new(0));
        let start = Instant::now();
        let run = move |t: usize, done: Arc<AtomicU64>| {
            let mut dec = Decoder::new(t as u64 + 1);
            while start.elapsed() < CPU_FOR {
                for _ in 0..64 {
                    dec.block();
                }
                done.fetch_add(64, Ordering::Relaxed);
            }
            std::hint::black_box(dec.out[0]);
        };
        let workers: Vec<_> = (0..threads)
            .filter_map(|t| {
                let done = done.clone();
                std::thread::Builder::new().name("bench".into()).spawn(move || run(t, done)).ok()
            })
            .collect();
        if workers.is_empty() {
            // no threads to be had: this one, a single core's worth
            run(0, done.clone());
        }
        // the gauge follows along here too
        while !workers.iter().all(|w| w.is_finished()) {
            std::thread::sleep(Duration::from_millis(200));
            let fps = device_fps(done.load(Ordering::Relaxed) as f64 / start.elapsed().as_secs_f64().max(0.001));
            crate::app::emit("benchDevice", json!({ "fps": fps, "score": lift(fps) }));
        }
        for w in workers {
            let _ = w.join();
        }
        done.load(Ordering::Relaxed) as f64 / start.elapsed().as_secs_f64()
    })
    .await?;
    let fps = device_fps(rate);
    Ok(json!({ "threads": threads, "fps": fps, "hardware": hardware, "score": lift(fps) }))
}

const PLANE: usize = 256;

/// one 16x16 block at a time: bins out of a cabac-style arithmetic decoder pick the residual,
/// an hevc 8-point inverse transform turns it into samples, an 8-tap filter predicts from the
/// reference plane, the sum is clipped to 10 bits
struct Decoder {
    bits: Vec<u8>,
    pos: usize,
    range: u32,
    value: u32,
    ctx: [u8; 64],
    reference: Vec<u16>,
    out: Vec<u16>,
    x: usize,
    y: usize,
}

impl Decoder {
    fn new(seed: u64) -> Self {
        let mut s = seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1;
        let mut next = move || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s
        };
        let bits = (0..1 << 16).map(|_| next() as u8).collect();
        let reference = (0..PLANE * PLANE).map(|_| (next() & 0x3ff) as u16).collect();
        Self { bits, pos: 0, range: 510, value: 0, ctx: [0; 64], reference, out: vec![0; PLANE * PLANE], x: 0, y: 0 }
    }

    fn byte(&mut self) -> u32 {
        self.pos = (self.pos + 1) & (self.bits.len() - 1);
        self.bits[self.pos] as u32
    }

    fn bin(&mut self, c: usize) -> u32 {
        let state = self.ctx[c];
        let lps = 2 + ((self.range >> 6) & 3) * 4 + (63 - state as u32) * 2;
        self.range -= lps;
        let bit = if self.value >= self.range << 7 {
            self.value -= self.range << 7;
            self.range = lps;
            self.ctx[c] = state.saturating_sub(1);
            1
        } else {
            self.ctx[c] = (state + 1).min(62);
            0
        };
        while self.range < 256 {
            self.range <<= 1;
            self.value = ((self.value << 1) | (self.byte() & 1)) & 0xffff;
        }
        bit
    }

    fn block(&mut self) {
        let mut coeff = [[0i32; 8]; 8];
        for (i, row) in coeff.iter_mut().enumerate() {
            for (j, c) in row.iter_mut().enumerate() {
                let ctx = (i * 8 + j) & 63;
                if self.bin(ctx) == 1 {
                    let mut level = 1;
                    while level < 16 && self.bin((ctx + level) & 63) == 1 {
                        level += 1;
                    }
                    *c = if self.bin(63) == 1 { -(level as i32) } else { level as i32 } * 16;
                }
            }
        }
        let rows = coeff.map(idct8);
        let mut res = [[0i32; 8]; 8];
        for j in 0..8 {
            let col = idct8(std::array::from_fn(|i| rows[i][j] >> 7));
            for i in 0..8 {
                res[i][j] = col[i] >> 12;
            }
        }
        const TAPS: [i32; 8] = [-1, 4, -11, 40, 40, -11, 4, -1];
        let (bx, by) = (self.x, self.y);
        for yy in 0..16 {
            for xx in 0..16 {
                let row = ((by + yy) % (PLANE - 8)) * PLANE + (bx + xx) % (PLANE - 8);
                let mut p = 0i32;
                for (k, t) in TAPS.iter().enumerate() {
                    p += t * self.reference[row + k] as i32;
                }
                let v = (p + 32) / 64 + res[yy & 7][xx & 7];
                self.out[row] = v.clamp(0, 1023) as u16;
            }
        }
        self.x = (self.x + 16) % PLANE;
        if self.x == 0 {
            self.y = (self.y + 16) % PLANE;
        }
        // the next block predicts from this one's output now and then, like a p frame
        if self.x == 0 && self.y == 0 {
            std::mem::swap(&mut self.reference, &mut self.out);
        }
    }
}

/// hevc's 8-point inverse transform (partial butterfly)
fn idct8(s: [i32; 8]) -> [i32; 8] {
    let o = [
        89 * s[1] + 75 * s[3] + 50 * s[5] + 18 * s[7],
        75 * s[1] - 18 * s[3] - 89 * s[5] - 50 * s[7],
        50 * s[1] - 89 * s[3] + 18 * s[5] + 75 * s[7],
        18 * s[1] - 50 * s[3] + 75 * s[5] - 89 * s[7],
    ];
    let eo = [83 * s[2] + 36 * s[6], 36 * s[2] - 83 * s[6]];
    let ee = [64 * s[0] + 64 * s[4], 64 * s[0] - 64 * s[4]];
    let e = [ee[0] + eo[0], ee[1] + eo[1], ee[1] - eo[1], ee[0] - eo[0]];
    [e[0] + o[0], e[1] + o[1], e[2] + o[2], e[3] + o[3], e[3] - o[3], e[2] - o[2], e[1] - o[1], e[0] - o[0]]
}

#[cfg(test)]
mod tests {
    #[test]
    fn scores() {
        assert_eq!(super::net_score(0.0), 0);
        assert_eq!(super::net_score(80.4), 80);
        assert_eq!(super::net_score(940.0), 100);
    }

    #[test]
    fn idct_dc() {
        assert_eq!(super::idct8([64, 0, 0, 0, 0, 0, 0, 0]), [4096; 8]);
    }

    // the work is plain integer math: every architecture must land on the same pixels
    #[test]
    fn same_everywhere() {
        let mut d = super::Decoder::new(1);
        for _ in 0..3000 {
            d.block();
        }
        let sum = d.out.iter().chain(&d.reference).fold(0u64, |h, &v| h.wrapping_mul(31).wrapping_add(v as u64));
        assert_eq!(sum, 7355553605840988953);
    }

    // prints the raw rate for calibrating BLOCKS_PER_FRAME: cargo test -- --ignored --nocapture calibrate
    #[test]
    #[ignore]
    fn calibrate() {
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        let start = std::time::Instant::now();
        let n: u64 = std::thread::scope(|sc| {
            let hs: Vec<_> = (0..threads)
                .map(|t| {
                    sc.spawn(move || {
                        let mut d = super::Decoder::new(t as u64 + 1);
                        let mut n = 0u64;
                        while start.elapsed() < super::CPU_FOR {
                            d.block();
                            n += 1;
                        }
                        n
                    })
                })
                .collect();
            hs.into_iter().map(|h| h.join().unwrap()).sum()
        });
        let rate = n as f64 / start.elapsed().as_secs_f64();
        println!("blocks/s {rate:.0} on {threads} threads = {} fps", super::device_fps(rate));
    }
}
