use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Serialize, Deserialize)]
struct Packet {
    id: u64,
    active: bool,
}

#[derive(Clone, Copy)]
struct Pair {
    left: u64,
    right: u64,
}

fn limit(base: u64) -> u64 {
    base + u64::from(std::thread::available_parallelism().is_ok())
}

fn text() {
    let haystack = String::from("abcdefghijklmnopabcdefghijklmnop");
    let n = limit(500_000);
    let mut checksum = 0u64;
    for _ in 0..n {
        assert_eq!(haystack.find("mnop"), Some(12));
        checksum = checksum.checked_add(12).unwrap();
    }
    assert_eq!(checksum, n * 12);
}

fn decimal() {
    let n = limit(5_000_000);
    let mut checksum = 0.0f64;
    for _ in 0..n {
        checksum += 1.5;
    }
    assert_eq!(checksum, 7_500_001.5);
}

fn make(value: u64) -> Pair {
    Pair {
        left: value,
        right: value.checked_add(1).unwrap(),
    }
}

fn record() {
    let n = limit(5_000_000);
    let mut checksum = 0u64;
    for index in 0..n {
        let pair = make(index);
        checksum = checksum
            .checked_add(pair.left)
            .unwrap()
            .checked_add(pair.right)
            .unwrap();
    }
    assert_eq!(checksum, n * n);
}

fn json() {
    let n = limit(100_000);
    let mut checksum = 0u64;
    for index in 0..n {
        let encoded = serde_json::to_string(&Packet {
            id: index % 1_000,
            active: true,
        })
        .unwrap();
        let decoded: Packet = serde_json::from_str(&encoded).unwrap();
        checksum = checksum.checked_add(decoded.id).unwrap();
        assert!(decoded.active);
    }
    assert_eq!(checksum, 49_950_000);
}

fn table() {
    let keys = vec![
        "amber", "blue", "cyan", "dusk", "ember", "frost", "green", "haze",
    ];
    let mut cache = HashMap::new();
    for (index, key) in keys.iter().enumerate() {
        cache.insert(*key, index as u64 + 1);
    }
    let n = limit(1_000_000);
    let mut checksum = 0u64;
    for index in 0..n {
        checksum = checksum
            .checked_add(*cache.get(keys[(index % 8) as usize]).unwrap())
            .unwrap();
    }
    assert_eq!(checksum, 4_500_001);
}

fn main() {
    match std::env::var("FOO_FEATURE_CASE").as_deref() {
        Ok("text") => text(),
        Ok("decimal") => decimal(),
        Ok("record") => record(),
        Ok("json") => json(),
        Ok("table") => table(),
        _ => panic!("set FOO_FEATURE_CASE"),
    }
}
