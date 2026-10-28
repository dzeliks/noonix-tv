// the picture size of a video file from its container header, for library files whose names
// don't say (matroska/webm, mp4/mov, avi). reads a few small pieces, never the whole file
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// width and height of the first video track
pub fn size(path: &Path) -> Option<(u32, u32)> {
    let mut f = File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let mut head = [0u8; 12];
    f.read_exact(&mut head).ok()?;
    f.seek(SeekFrom::Start(0)).ok()?;
    if head[..4] == [0x1A, 0x45, 0xDF, 0xA3] {
        matroska(&mut f, len)
    } else if &head[..4] == b"RIFF" && &head[8..12] == b"AVI " {
        avi(&mut f)
    } else if matches!(&head[4..8], b"ftyp" | b"moov" | b"mdat" | b"wide" | b"free" | b"skip") {
        mp4(&mut f, 0, len, 0)
    } else {
        None
    }
}

/// the usual name for a picture size: 1920x800 is still 1080p
pub fn resolution(w: u32, h: u32) -> u32 {
    match (w, h) {
        _ if w >= 3200 || h >= 1800 => 2160,
        _ if w >= 2200 || h >= 1300 => 1440,
        _ if w >= 1700 || h >= 900 => 1080,
        _ if w >= 1100 || h >= 650 => 720,
        _ if h >= 400 => 480,
        _ => 0,
    }
}

// ---- matroska: segment > tracks > track entry > video > pixel width / height

fn vint(f: &mut File, keep_marker: bool) -> Option<(u64, u64)> {
    let mut b = [0u8; 1];
    f.read_exact(&mut b).ok()?;
    let n = b[0].leading_zeros() as u64 + 1;
    if n > 8 {
        return None;
    }
    let mut v = if keep_marker { b[0] as u64 } else { (b[0] as u64) & (0xFF >> n) };
    for _ in 1..n {
        f.read_exact(&mut b).ok()?;
        v = (v << 8) | b[0] as u64;
    }
    // all ones: unknown size (a live segment)
    let unknown = !keep_marker && v == (1u64 << (7 * n)) - 1;
    Some((if unknown { u64::MAX } else { v }, n))
}

fn uint(f: &mut File, size: u64) -> Option<u64> {
    if size > 8 {
        return None;
    }
    let mut v = 0u64;
    let mut b = [0u8; 1];
    for _ in 0..size {
        f.read_exact(&mut b).ok()?;
        v = (v << 8) | b[0] as u64;
    }
    Some(v)
}

/// walks the children between start and end; on finds an id the caller wants, returns its answer
fn children<T>(f: &mut File, start: u64, end: u64, mut on: impl FnMut(&mut File, u64, u64, u64) -> Option<Option<T>>) -> Option<T> {
    let mut pos = start;
    let mut steps = 0;
    while pos < end && steps < 4096 {
        steps += 1;
        f.seek(SeekFrom::Start(pos)).ok()?;
        let (id, idn) = vint(f, true)?;
        let (size, sn) = vint(f, false)?;
        let body = pos + idn + sn;
        let next = if size == u64::MAX { end } else { body.checked_add(size)? };
        if let Some(found) = on(f, id, body, next.min(end)) {
            return found;
        }
        if next <= pos {
            return None;
        }
        pos = next;
    }
    None
}

fn matroska(f: &mut File, len: u64) -> Option<(u32, u32)> {
    children(f, 0, len, |f, id, body, end| match id {
        0x18538067 => Some(children(f, body, end, |f, id, body, end| match id {
            0x1654AE6B => Some(tracks(f, body, end)),
            // the picture comes before the first cluster
            0x1F43B675 => Some(None),
            _ => None,
        })),
        _ => None,
    })
}

fn tracks(f: &mut File, start: u64, end: u64) -> Option<(u32, u32)> {
    children(f, start, end, |f, id, body, end| {
        if id != 0xAE {
            return None;
        }
        let video = children(f, body, end, |f, id, body, end| {
            if id != 0xE0 {
                return None;
            }
            let (mut w, mut h) = (0, 0);
            children::<()>(f, body, end, |f, id, _, end| {
                let pos = f.stream_position().ok()?;
                match id {
                    0xB0 => w = uint(f, end - pos)? as u32,
                    0xBA => h = uint(f, end - pos)? as u32,
                    _ => {}
                }
                None
            });
            Some((w > 0 && h > 0).then_some((w, h)))
        });
        video.map(Some)
    })
}

// ---- mp4 / mov: moov > trak > tkhd, width and height as 16.16 at its end

fn mp4(f: &mut File, start: u64, end: u64, depth: u32) -> Option<(u32, u32)> {
    let mut pos = start;
    let mut steps = 0;
    while pos + 8 <= end && steps < 4096 {
        steps += 1;
        f.seek(SeekFrom::Start(pos)).ok()?;
        let mut h = [0u8; 8];
        f.read_exact(&mut h).ok()?;
        let mut size = u32::from_be_bytes(h[..4].try_into().ok()?) as u64;
        let kind = &h[4..8];
        let mut body = pos + 8;
        if size == 1 {
            let mut b = [0u8; 8];
            f.read_exact(&mut b).ok()?;
            size = u64::from_be_bytes(b);
            body += 8;
        } else if size == 0 {
            size = end - pos;
        }
        if size < 8 {
            return None;
        }
        let next = pos.checked_add(size)?.min(end);
        match kind {
            b"moov" | b"trak" if depth < 3 => {
                if let Some(found) = mp4(f, body, next, depth + 1) {
                    return Some(found);
                }
            }
            b"tkhd" => {
                let mut b = [0u8; 8];
                f.seek(SeekFrom::Start(next.checked_sub(8)?)).ok()?;
                f.read_exact(&mut b).ok()?;
                let w = u32::from_be_bytes(b[..4].try_into().ok()?) >> 16;
                let h = u32::from_be_bytes(b[4..].try_into().ok()?) >> 16;
                // audio tracks are 0x0
                if w > 0 && h > 0 {
                    return Some((w, h));
                }
            }
            _ => {}
        }
        pos = next;
    }
    None
}

// ---- avi: the main header (avih) near the start

fn avi(f: &mut File) -> Option<(u32, u32)> {
    let mut head = vec![0u8; 4096];
    let n = f.read(&mut head).ok()?;
    let at = head[..n].windows(4).position(|w| w == b"avih")? + 8;
    let word = |o: usize| head.get(at + o..at + o + 4).and_then(|b| b.try_into().ok()).map(u32::from_le_bytes);
    let (w, h) = (word(32)?, word(36)?);
    (w > 0 && h > 0).then_some((w, h))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_picture_sizes() {
        assert_eq!(resolution(3840, 1600), 2160);
        assert_eq!(resolution(1920, 800), 1080);
        assert_eq!(resolution(1920, 1080), 1080);
        assert_eq!(resolution(1280, 534), 720);
        assert_eq!(resolution(1024, 576), 480);
        assert_eq!(resolution(320, 180), 0);
    }

    // NOONIX_PROBE=<file> cargo test probe_a_file -- --ignored --nocapture
    #[test]
    #[ignore]
    fn probe_a_file() {
        let p = std::env::var("NOONIX_PROBE").unwrap();
        println!("{:?}", size(Path::new(&p)));
    }
}
