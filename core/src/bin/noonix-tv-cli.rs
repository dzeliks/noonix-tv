// dev tool: noonix-tv-cli <method> [json] [<method> [json]]...   e.g. noonix-tv-cli home.row '{"id":"trending-tv"}'
// several calls share one process (a library scan or extension sync started by one finishes);
// "@last" in a call's json is the previous answer's token (extensions.preview, then .install)
use noonix_core::{app, rpc};

fn main() {
    app::init_logging();
    noonix_core::config::init_secrets();
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: noonix-tv-cli <method> [json] ...");
        std::process::exit(2);
    }
    let mut calls = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let method = args[i].clone();
        let json = match args.get(i + 1) {
            Some(a) if a.trim_start().starts_with('{') || a.trim_start().starts_with('[') => {
                i += 1;
                serde_json::from_str(a).expect("json")
            }
            _ => serde_json::Value::Null,
        };
        calls.push((method, json));
        i += 1;
    }
    let mut failed = false;
    let mut last = String::new();
    for (method, json) in calls {
        let t = std::time::Instant::now();
        let json: serde_json::Value = serde_json::from_str(&json.to_string().replace("\"@last\"", &serde_json::to_string(&last).unwrap())).unwrap();
        match app::RUNTIME.block_on(rpc::dispatch(&method, json)) {
            Ok(v) => {
                last = v.get("token").and_then(|t| t.as_str()).unwrap_or("").to_owned();
                println!("{}", serde_json::to_string_pretty(&v).unwrap())
            }
            Err(e) => {
                eprintln!("error: {e:#}");
                failed = true;
            }
        }
        eprintln!("[{method} {} ms]", t.elapsed().as_millis());
    }
    std::process::exit(failed as i32);
}
