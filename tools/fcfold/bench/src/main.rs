// time the per-set path's phases on a dumped function: AIR specialization, the visible-reference closure, the translation
use std::time::Instant;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a[1] == "--dis" {   // fcb --dis FILE.spv
        println!("{}", metal2vulkan::disassemble(&std::fs::read(&a[2]).unwrap()).unwrap());
        return;
    }
    if a[1] == "--ll" {   // translate a text as it is: fcb --ll FILE STAGE OUT.spv
        let stage = match a[3].as_str() { "fragment" => metal2vulkan::passes::Stage::Fragment, "vertex" => metal2vulkan::passes::Stage::Vertex, _ => metal2vulkan::passes::Stage::Kernel };
        let ll = std::fs::read_to_string(&a[2]).unwrap();
        let t0 = Instant::now();
        let cl = metal2vulkan::linked_functions::specialize_visible_function_references(&ll, &metal2vulkan::linked_functions::LinkedFunctionLinkage::default()).unwrap();
        let spv = metal2vulkan::with_parse_cache(|| metal2vulkan::translate_native_no_retry_constructed_with_options(cl.as_str(), stage, metal2vulkan::passes::TransformOptions::default()));
        let dt = t0.elapsed().as_millis();
        match spv { Ok(v) => { std::fs::write(&a[4], &v).unwrap(); println!("{} -> {} B SPIR-V in {dt} ms", a[2], v.len()); }
                    Err(e) => println!("{}: error {e:?}", a[2]) }
        return;
    }
    let base = &a[1];
    let n: usize = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(3);
    let stage = if base.contains("-fragment-") { metal2vulkan::passes::Stage::Fragment } else if base.contains("-vertex-") { metal2vulkan::passes::Stage::Vertex } else { metal2vulkan::passes::Stage::Kernel };
    let ll = std::fs::read_to_string(format!("{base}.ll")).unwrap();
    let sets = std::fs::read_to_string(format!("{base}.fc")).unwrap();
    for (si, line) in sets.lines().filter(|l| !l.trim().is_empty()).take(n).enumerate() {
        let values: Vec<(u32, Vec<u8>)> = line.split_whitespace().map(|kv| {
            let (k, v) = kv.split_once(':').unwrap();
            (k.parse().unwrap(), (0..v.len() / 2).map(|i| u8::from_str_radix(&v[2 * i..2 * i + 2], 16).unwrap()).collect())
        }).collect();
        let t0 = Instant::now();
        let sp = metal2vulkan::specialize_air_function_constants(&ll, &values).unwrap();
        let t1 = Instant::now();
        let cl = metal2vulkan::linked_functions::specialize_visible_function_references(sp.as_ref(), &metal2vulkan::linked_functions::LinkedFunctionLinkage::default()).unwrap();
        let t2 = Instant::now();
        let spv = metal2vulkan::with_parse_cache(|| metal2vulkan::translate_native_no_retry_constructed_with_options(cl.as_str(), stage, metal2vulkan::passes::TransformOptions::default()));
        let t3 = Instant::now();
        if let Ok(d) = std::env::var("FCB_DUMP") { std::fs::write(format!("{d}/spec-{si}.ll"), cl.as_str()).unwrap(); }
        println!("specialize {:>4} ms ({} -> {} B text)  visible {:>4} ms  translate {:>4} ms ({} B SPIR-V)",
            (t1 - t0).as_millis(), ll.len(), sp.len(), (t2 - t1).as_millis(), (t3 - t2).as_millis(), spv.map(|v| v.len()).unwrap_or(0));
    }
}
