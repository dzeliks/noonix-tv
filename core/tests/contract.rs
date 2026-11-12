// every method the qml and swift clients name is one the core answers or an event it pushes. the
// names are read from the sources: match arms and emit()s in core/src, and in the clients any string
// that looks like "domain.call" for a domain the core has (ternaries and variables count too)
use std::collections::BTreeSet;
use std::path::Path;

fn files(dir: &Path, ext: &str, out: &mut Vec<String>) {
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            files(&p, ext, out);
        } else if p.extension().is_some_and(|x| x == ext) {
            out.push(std::fs::read_to_string(&p).unwrap());
        }
    }
}

/// the string literals in a source, quotes dropped
fn strings(src: &str) -> Vec<&str> {
    src.split('"').skip(1).step_by(2).collect()
}

fn method_like(s: &str) -> bool {
    let mut parts = s.split('.');
    let first = parts.next().unwrap_or("");
    !first.is_empty()
        && first.bytes().all(|b| b.is_ascii_lowercase())
        && s.contains('.')
        && parts.all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphabetic()))
}

#[test]
fn clients_call_only_what_the_core_answers() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut core = Vec::new();
    files(&root.join("src"), "rs", &mut core);
    // `"a.b" =>` and `"a.b" | "a.c" =>`
    let mut answered = BTreeSet::new();
    for src in &core {
        for line in src.lines() {
            let t = line.trim();
            let Some(arms) = t.strip_suffix("=> {").or_else(|| t.split_once(" => ").map(|(a, _)| a)) else { continue };
            if arms.starts_with('"') && arms.split('|').all(|a| a.trim().starts_with('"') && a.trim().ends_with('"')) {
                answered.extend(arms.split('|').map(|a| a.trim().trim_matches('"').to_owned()));
            }
        }
    }
    assert!(answered.len() > 80, "found only {} methods in the core: has dispatch moved?", answered.len());
    // and what it pushes (emit("playback.skip", ..)), which the clients listen for by name
    for src in &core {
        for part in src.split("emit(\"").skip(1) {
            answered.insert(part.split('"').next().unwrap().to_owned());
        }
    }
    let domains: BTreeSet<&str> = answered.iter().filter_map(|m| m.split_once('.').map(|d| d.0)).collect();

    let mut clients = Vec::new();
    files(&root.join("../qml"), "qml", &mut clients);
    files(&root.join("../mac/Sources"), "swift", &mut clients);
    let mut missing = BTreeSet::new();
    let mut called = 0;
    for src in &clients {
        for s in strings(src) {
            if method_like(s) && domains.contains(s.split('.').next().unwrap()) {
                called += 1;
                if !answered.contains(s) {
                    missing.insert(s.to_owned());
                }
            }
        }
    }
    assert!(called > 100, "found only {called} calls in the clients");
    assert!(missing.is_empty(), "the clients call methods the core doesn't answer: {missing:?}");
}
