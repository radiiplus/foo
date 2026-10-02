use std::cell::RefCell;
use std::env;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Default)]
struct Metrics {
    allocations: u64,
    allocated: u64,
    reallocations: u64,
    copied: u64,
    growths: u64,
    growthcopied: u64,
    capacitytotal: u64,
    capacitymax: u64,
    requested: u64,
    live: u64,
    peak: u64,
    retained: u64,
    slow: u64,
    branches: u64,
    branchcopied: u64,
}

static SINK: AtomicU64 = AtomicU64::new(0);

fn reserve(count: usize, metrics: &mut Metrics) -> Vec<u64> {
    let bytes = count as u64 * 8;
    metrics.allocations += 1;
    metrics.allocated += bytes;
    metrics.live += bytes;
    metrics.peak = metrics.peak.max(metrics.live);
    vec![0; count]
}

fn release(values: Vec<u64>, metrics: &mut Metrics) {
    metrics.live -= values.len() as u64 * 8;
    drop(values);
}

struct Buffer {
    data: Vec<u64>,
    used: usize,
    retired: bool,
}

#[derive(Clone, Default)]
struct View {
    buffer: Option<Rc<RefCell<Buffer>>>,
    length: usize,
}

fn capacity(count: usize) -> usize {
    let mut result = 8;
    while result < count {
        result *= 2;
    }
    result
}

fn append(source: &View, value: u64, metrics: &mut Metrics) -> View {
    let count = source.length + 1;
    let mut available = capacity(count);
    metrics.growths += 1;
    metrics.requested += count as u64;
    if let Some(buffer) = &source.buffer {
        let inplace = {
            let current = buffer.borrow();
            source.length == current.used && current.used < current.data.len()
        };
        if inplace {
            let mut current = buffer.borrow_mut();
            current.data[source.length] = value;
            current.used = count;
            metrics.capacitytotal += current.data.len() as u64;
            metrics.capacitymax = metrics.capacitymax.max(current.data.len() as u64);
            return View { buffer: Some(buffer.clone()), length: count };
        }
    }
    let branch = source.buffer.as_ref().is_some_and(|buffer| source.length < buffer.borrow().used);
    if let Some(buffer) = &source.buffer {
        if !branch {
            let mut current = buffer.borrow_mut();
            available = current.data.len() * 2;
            if !current.retired {
                current.retired = true;
                metrics.retained += current.data.len() as u64 * 8;
            }
        }
    }
    let mut data = reserve(available, metrics);
    if let Some(previous) = &source.buffer {
        data[..source.length].copy_from_slice(&previous.borrow().data[..source.length]);
        let bytes = source.length as u64 * 8;
        metrics.copied += bytes;
        metrics.growthcopied += bytes;
        if branch {
            metrics.branches += 1;
            metrics.branchcopied += bytes;
        }
    }
    data[source.length] = value;
    metrics.slow += 1;
    metrics.capacitytotal += available as u64;
    metrics.capacitymax = metrics.capacitymax.max(available as u64);
    View {
        buffer: Some(Rc::new(RefCell::new(Buffer { data, used: count, retired: false }))),
        length: count,
    }
}

fn discard(value: View, metrics: &mut Metrics) {
    if let Some(buffer) = value.buffer {
        let bytes = buffer.borrow().data.len() as u64 * 8;
        metrics.live -= bytes;
        if buffer.borrow().retired {
            metrics.retained -= bytes;
        }
    }
}

#[inline(never)]
fn next(value: u64) -> u64 { value + 1 }

#[inline(never)]
fn failable(value: u64) -> Result<u64, ()> { Ok(value + 1) }

fn identity<T>(value: T) -> T { value }

fn arithmetic(limit: u64) -> bool {
    let mut total = 0u64;
    for index in 0..limit { total = total.wrapping_add(index); }
    SINK.store(total, Ordering::Relaxed);
    total == 0
}

fn calls(limit: u64) -> bool {
    let mut total = 0u64;
    for index in 0..limit { total = total.wrapping_add(next(index)); }
    SINK.store(total, Ordering::Relaxed);
    total == 0
}

fn failure(limit: u64) -> Result<bool, ()> {
    let mut total = 0u64;
    for index in 0..limit { total = total.wrapping_add(failable(index)?); }
    SINK.store(total, Ordering::Relaxed);
    Ok(total == 0)
}

fn generic(limit: u64) -> bool {
    let mut total = 0u64;
    for index in 0..limit { total = total.wrapping_add(identity(index)); }
    SINK.store(total, Ordering::Relaxed);
    total == 0
}

fn allocation(metrics: &mut Metrics) -> bool {
    let mut values = reserve(10_000, metrics);
    let mut doubled = reserve(10_000, metrics);
    for (index, value) in values.iter_mut().enumerate() { *value = index as u64; }
    for (value, result) in values.iter().zip(doubled.iter_mut()) { *result = value * 2; }
    let last = doubled[9_999];
    SINK.store(last, Ordering::Relaxed);
    release(doubled, metrics);
    release(values, metrics);
    last != 19_998
}

fn growth(metrics: &mut Metrics) -> bool {
    let mut values = View::default();
    let mut older = View::default();
    for index in 0..10_000 {
        values = append(&values, index, metrics);
        if index + 1 == 5_000 { older = values.clone(); }
    }
    let branched = append(&older, 50_000, metrics);
    let current = values.buffer.as_ref().unwrap().borrow().data[9_999];
    let branch = branched.buffer.as_ref().unwrap().borrow().data[5_000];
    let old = older.buffer.as_ref().unwrap().borrow().data[4_999];
    let preserved = values.buffer.as_ref().unwrap().borrow().data[5_000];
    SINK.store(current + branch, Ordering::Relaxed);
    let failed = older.length != 5_000 || old != 4_999 || preserved != 5_000 || branch != 50_000;
    discard(branched, metrics);
    failed
}

fn branching(metrics: &mut Metrics) -> bool {
    let mut values = View::default();
    let mut older = View::default();
    for index in 0..10_000 {
        values = append(&values, index, metrics);
        if index + 1 == 5_000 { older = values.clone(); }
    }
    let mut checksum = 0u64;
    for index in 0..1_000 {
        let result = append(&older, index, metrics);
        checksum += result.buffer.as_ref().unwrap().borrow().data[5_000];
        discard(result, metrics);
    }
    SINK.store(checksum, Ordering::Relaxed);
    checksum != 499_500 || older.buffer.as_ref().unwrap().borrow().data[4_999] != 4_999 ||
        values.buffer.as_ref().unwrap().borrow().data[5_000] != 5_000
}

fn lookup(metrics: &mut Metrics) -> bool {
    let mut values = reserve(10_000, metrics);
    for (index, value) in values.iter_mut().enumerate() { *value = index as u64; }
    let mut checksum = 0u64;
    for index in 0..1_000_000 { checksum += values[index % values.len()]; }
    SINK.store(checksum, Ordering::Relaxed);
    release(values, metrics);
    checksum != 4_999_500_000
}

fn iteration(metrics: &mut Metrics) -> bool {
    let mut values = reserve(1_000_000, metrics);
    for (index, value) in values.iter_mut().enumerate() { *value = index as u64; }
    let checksum: u64 = values.iter().copied().sum();
    SINK.store(checksum, Ordering::Relaxed);
    release(values, metrics);
    checksum != 499_999_500_000
}

fn report(metrics: &Metrics) {
    let average = if metrics.growths == 0 { 0.0 } else { metrics.capacitytotal as f64 / metrics.growths as f64 };
    let factor = if metrics.requested == 0 { 0.0 } else { metrics.capacitytotal as f64 / metrics.requested as f64 };
    eprintln!("FOO_METRICS {{\"allocations\":{},\"allocatedBytes\":{},\"reallocations\":{},\"bytesCopied\":{},\"growthOperations\":{},\"growthBytesCopied\":{},\"averageCapacity\":{:.3},\"maximumCapacity\":{},\"growthFactor\":{:.3},\"liveBytes\":{},\"peakBytes\":{},\"olderVersionBytes\":{},\"slowPathHits\":{},\"branchOperations\":{},\"branchBytesCopied\":{}}}",
        metrics.allocations, metrics.allocated, metrics.reallocations, metrics.copied,
        metrics.growths, metrics.growthcopied, average, metrics.capacitymax, factor,
        metrics.live, metrics.peak, metrics.retained, metrics.slow, metrics.branches,
        metrics.branchcopied);
}

fn main() {
    let arguments: Vec<String> = env::args().collect();
    if arguments.len() != 3 { std::process::exit(2); }
    let cores = arguments[2].parse::<u64>().unwrap_or(0);
    if cores == 0 { std::process::exit(2); }
    let limit = 10_000_000 + u64::from(cores > 0);
    let mut metrics = Metrics::default();
    let failed = match arguments[1].as_str() {
        "startup" => false,
        "known" => 499_999_500_000u64 == 0,
        "runtime" => cores == 0,
        "arithmetic" => arithmetic(limit),
        "calls" => calls(limit),
        "failure" => failure(limit).unwrap_or(true),
        "generic" => generic(limit),
        "allocation" => allocation(&mut metrics),
        "branch" => branching(&mut metrics),
        "growth" => growth(&mut metrics),
        "iteration" => iteration(&mut metrics),
        "lookup" => lookup(&mut metrics),
        _ => std::process::exit(2),
    };
    report(&metrics);
    if failed { std::process::exit(1); }
}
