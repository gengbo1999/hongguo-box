//! hg-signer：红果 7.4.3.32 签名 sidecar。
//!
//! 只做编解码与签名，不发 HTTP：Python 侧（`server/hg/signer_v5.py`）负责取材料、跑 SDI 交换与取流。
//! 约定：入参/出参都是 JSON（stdin 或文件），body 用 base64 传递。

use std::io::Read;
use std::path::Path;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use hg_signer::device::DeviceProfile;
use hg_signer::metasec::{self, Materials, SignedRequest};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("cache") => cache(&args[1..]),
        Some("sdi-encode") => sdi_encode(&args[1..]),
        Some("sdi-decode") => sdi_decode(&args[1..]),
        Some("sign") => sign(&args[1..]),
        Some("info") => info(&args[1..]),
        Some("probe") => probe(&args[1..]),
        Some("serve") => return serve(&args[1..]),
        _ => Err(usage()),
    };
    match result {
        Ok(json) => println!("{json}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

fn usage() -> String {
    "用法: hg-signer <cache|info|sdi-encode|sdi-decode|sign> ...".to_string()
}

/// `cache <dex.part> <elf.part> <cache.bin>`：校验两段材料并落地缓存。
fn cache(args: &[String]) -> Result<serde_json::Value, String> {
    let (dex, elf, out) = match args {
        [dex, elf, out] => (dex, elf, out),
        _ => return Err("用法: hg-signer cache <dex.part> <elf.part> <cache.bin>".to_string()),
    };
    let dex_part = std::fs::read(dex).map_err(|error| format!("读 DEX 段失败: {error}"))?;
    let elf_part = std::fs::read(elf).map_err(|error| format!("读 ELF 段失败: {error}"))?;
    let materials = Materials::build(&dex_part, &elf_part, Some(Path::new(out)))?;
    Ok(serde_json::json!({
        "cache": out,
        "dex": materials.dex.len(),
        "elf": materials.elf.len(),
        "common_key": STANDARD.encode(materials.signer.common_key()),
    }))
}

/// `info <cache>`：自检材料能否解释出签名材料。
fn info(args: &[String]) -> Result<serde_json::Value, String> {
    let [cache] = args else {
        return Err("用法: hg-signer info <cache.bin>".to_string());
    };
    let materials = Materials::load(Path::new(cache))?;
    let image = materials.image();
    let digest = image
        .digest(&[7u8; 32], &[9u8; 16], 1_762_000_000)
        .map_err(|error| format!("F13 求值失败: {error}"))?;
    Ok(serde_json::json!({
        "dex": materials.dex.len(),
        "elf": materials.elf.len(),
        "common_key": STANDARD.encode(materials.signer.common_key()),
        "sdi_inner_key": hex::encode(image.sdi_inner_key()),
        "unavailable_string": image.unavailable_string(),
        "digest": hex::encode(digest),
    }))
}

/// `sdi-encode <cache> <device.json> [token]`：生成 SDI token 交换请求。
fn sdi_encode(args: &[String]) -> Result<serde_json::Value, String> {
    if args.len() < 2 {
        return Err("用法: hg-signer sdi-encode <cache> <device.json> [token]".to_string());
    }
    let materials = Materials::load(Path::new(&args[0]))?;
    let device = load_device(&args[1])?;
    let token = args.get(2).map(String::as_str);
    signed_json(&metasec::sdi_request(&materials, &device, token)?, 0)
}

/// `sdi-decode <cache> <packet.bin>`：解出 SDI token。
fn sdi_decode(args: &[String]) -> Result<serde_json::Value, String> {
    let [cache, packet] = args else {
        return Err("用法: hg-signer sdi-decode <cache> <packet.bin>".to_string());
    };
    let materials = Materials::load(Path::new(cache))?;
    let bytes = std::fs::read(packet).map_err(|error| format!("读响应失败: {error}"))?;
    let token = materials.codec().decode_response(&bytes)?;
    Ok(serde_json::json!({ "token": token.value, "status": token.status }))
}

/// `sign <cache> <device.json> <path> <body.bin> [--origin O] [--token T] [--ladon N]`
fn sign(args: &[String]) -> Result<serde_json::Value, String> {
    if args.len() < 4 {
        return Err(
            "用法: hg-signer sign <cache> <device.json> <path> <body.bin> [--origin O] [--token T] [--ladon N]"
                .to_string(),
        );
    }
    let (mut origin, mut token, mut ladon) = (
        "https://api5-normal-sinfonlinea.fqnovel.com".to_string(),
        None,
        0u32,
    );
    let mut index = 4;
    while index < args.len() {
        match args[index].as_str() {
            "--origin" => {
                origin = args.get(index + 1).cloned().ok_or("--origin 缺值")?;
                index += 2;
            }
            "--token" => {
                token = Some(args.get(index + 1).cloned().ok_or("--token 缺值")?);
                index += 2;
            }
            "--ladon" => {
                ladon = args
                    .get(index + 1)
                    .and_then(|value| value.parse().ok())
                    .ok_or("--ladon 缺值")?;
                index += 2;
            }
            other => return Err(format!("未知参数: {other}")),
        }
    }
    let materials = Materials::load(Path::new(&args[0]))?;
    let device = load_device(&args[1])?;
    let body = std::fs::read(&args[3]).map_err(|error| format!("读请求体失败: {error}"))?;
    let signed = metasec::playback_request(
        &materials,
        &device,
        &origin,
        &args[2],
        body,
        token.as_deref(),
        &mut ladon,
    )?;
    signed_json(&signed, ladon)
}

/// 头列表 → JSON 对象（Python 侧按 dict 用，避免再拆 [k, v] 数组）。
fn headers_json(headers: &[(String, String)]) -> serde_json::Value {
    let mut map = serde_json::Map::with_capacity(headers.len());
    for (key, value) in headers {
        map.insert(key.clone(), serde_json::Value::String(value.clone()));
    }
    serde_json::Value::Object(map)
}

/// `probe <cache>`：固定输入的签名探针，用于与上游 Rust 实现对拍。
fn probe(args: &[String]) -> Result<serde_json::Value, String> {
    use hg_signer::medusa_v5::{RequestContext, RequestEntropy, RequestSigner};

    let [cache] = args else {
        return Err("用法: hg-signer probe <cache.bin>".to_string());
    };
    let materials = Materials::load(Path::new(cache))?;
    let signer: &RequestSigner = &materials.signer;
    let counters: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    let environment: [u8; 30] = std::array::from_fn(|index| index as u8 + 10);
    let context = RequestContext {
        device_id: "1905892595378490",
        version_name: "7.4.3.32",
        token: Some("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
        counters: &counters,
        environment: &environment,
        runtime_json: r#"{"cmr":16777216,"cmr2":16777216,"vpn":0,"kd":0,"dyn":"","do":0,"tk":true}"#,
        flags: 0x0504,
        ladon: 0x1234,
    };
    let entropy = RequestEntropy {
        message: 1,
        envelope: 2,
        packed: 3,
        gorgon: 4,
        helios: 5,
    };
    let factors = signer
        .factors("a=1&b=2", Some(b"hello"), 1_762_000_000, &context, &entropy)
        .map_err(|error| format!("签名失败: {error}"))?;
    let lines: Vec<String> = factors
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect();
    Ok(serde_json::json!({ "ok": true, "lines": lines }))
}

fn signed_json(signed: &SignedRequest, ladon: u32) -> Result<serde_json::Value, String> {
    Ok(serde_json::json!({
        "url": signed.url,
        "headers": headers_json(&signed.headers),
        "body": STANDARD.encode(&signed.body),
        "ladon": ladon,
    }))
}

fn load_device(path: &str) -> Result<DeviceProfile, String> {
    let mut text = String::new();
    std::fs::File::open(path)
        .map_err(|error| format!("读设备档案失败: {error}"))?
        .read_to_string(&mut text)
        .map_err(|error| format!("读设备档案失败: {error}"))?;
    let map: serde_json::Map<String, serde_json::Value> =
        serde_json::from_str(&text).map_err(|error| format!("设备档案不是 JSON 对象: {error}"))?;
    let fields = map
        .into_iter()
        .filter_map(|(key, value)| match value {
            serde_json::Value::String(text) => Some((key, text)),
            serde_json::Value::Number(number) => Some((key, number.to_string())),
            _ => None,
        })
        .collect();
    Ok(DeviceProfile::from_owned_fields(fields, hg_signer::device::video_ua()))
}
/// `serve <cache.bin>`：JSON Lines 常驻模式，供 Python 侧的 HTTP 服务调用。
///
/// 每行一个请求对象，`op` 取 `device`/`sdi`/`sdi-decode`/`sign`/`info`；
/// 每行一个响应对象，失败时返回 `{"ok":false,"error":...}` 且进程继续。
fn serve(args: &[String]) -> ! {
    use std::io::{BufRead, Write};

    let cache = args
        .first()
        .cloned()
        .unwrap_or_else(|| "metasec-v5-74332.cache".to_string());
    let mut device: Option<DeviceProfile> = None;
    let materials = match Materials::load(Path::new(&cache)) {
        Ok(materials) => materials,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    };
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = handle(&materials, &line, &mut device);
        let _ = writeln!(stdout, "{reply}");
        let _ = stdout.flush();
    }
    std::process::exit(0)
}

fn handle(
    materials: &Materials,
    line: &str,
    device: &mut Option<DeviceProfile>,
) -> serde_json::Value {
    let request: serde_json::Value = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => return serde_json::json!({"ok": false, "error": format!("请求不是 JSON: {error}")}),
    };
    if let Some(fields) = request.get("device") {
        match device_from_value(fields) {
            Ok(profile) => *device = Some(profile),
            Err(error) => return serde_json::json!({"ok": false, "error": error}),
        }
    }
    // 匿名读播档案：给 cdid 就生成官方游客档案（无 iid/device_id、零 cookie），
    // 回传字段供 Python 侧缓存，后续请求直接带 `device` 复用同一身份。
    if request.get("op").and_then(|value| value.as_str()) == Some("anonymous") {
        let cdid = request
            .get("cdid")
            .and_then(|value| value.as_str())
            .map(str::to_owned)
            .filter(|value| !value.is_empty())
            .unwrap_or_else(hg_signer::device::fresh_cdid);
        let profile = hg_signer::device::anonymous_profile(&cdid);
        *device = Some(profile);
        let current = device.as_ref().expect("刚写入");
        let fields: serde_json::Map<String, serde_json::Value> = current
            .fields()
            .iter()
            .map(|(key, value)| (key.clone(), serde_json::Value::String(value.clone())))
            .collect();
        return serde_json::json!({"ok": true, "cdid": cdid, "device": fields});
    }
    let Some(profile) = device.as_ref() else {
        return serde_json::json!({"ok": false, "error": "还没有设置设备档案"});
    };
    let op = request.get("op").and_then(|value| value.as_str()).unwrap_or("");
    let text = |key: &str| request.get(key).and_then(|value| value.as_str()).map(str::to_owned);
    let result = match op {
        "device" => Ok(serde_json::json!({"ok": true})),
        "info" => Ok(serde_json::json!({
            "ok": true,
            "dex": materials.dex.len(),
            "elf": materials.elf.len(),
            "common_key": STANDARD.encode(materials.signer.common_key()),
            "unavailable_string": materials.image().unavailable_string(),
        })),
        "sdi" => metasec::sdi_request(materials, profile, text("token").as_deref())
            .map(|signed| {
                serde_json::json!({
                    "ok": true,
                    "url": signed.url,
                    "headers": headers_json(&signed.headers),
                    "body": STANDARD.encode(&signed.body),
                })
            })
            .map_err(|error| serde_json::json!({"ok": false, "error": error})),
        "sdi-decode" => (|| {
            let packet = STANDARD
                .decode(request.get("packet").and_then(|value| value.as_str()).unwrap_or(""))
                .map_err(|_| serde_json::json!({"ok": false, "error": "packet 不是 base64"}))?;
            let token = materials
                .codec()
                .decode_response(&packet)
                .map_err(|error| serde_json::json!({"ok": false, "error": error}))?;
            Ok(serde_json::json!({"ok": true, "token": token.value, "status": token.status}))
        })(),
        "sign" => (|| {
            let body = STANDARD
                .decode(request.get("body").and_then(|value| value.as_str()).unwrap_or(""))
                .map_err(|_| serde_json::json!({"ok": false, "error": "body 不是 base64"}))?;
            let origin = text("origin")
                .unwrap_or_else(|| "https://api5-normal-sinfonlinea.fqnovel.com".to_string());
            let path = text("path").ok_or_else(|| serde_json::json!({"ok": false, "error": "缺少 path"}))?;
            let mut ladon = request
                .get("ladon")
                .and_then(|value| value.as_u64())
                .unwrap_or(0) as u32;
            let signed = metasec::playback_request(
                materials,
                profile,
                &origin,
                &path,
                body,
                text("token").as_deref(),
                &mut ladon,
            )
            .map_err(|error| serde_json::json!({"ok": false, "error": error}))?;
            Ok(serde_json::json!({
                "ok": true,
                "url": signed.url,
                "headers": headers_json(&signed.headers),
                "body": STANDARD.encode(&signed.body),
                "ladon": ladon,
            }))
        })(),
        other => Err(serde_json::json!({"ok": false, "error": format!("未知 op: {other}")})),
    };
    result.unwrap_or_else(|error| error)
}

fn device_from_value(value: &serde_json::Value) -> Result<DeviceProfile, String> {
    let map = value
        .as_object()
        .ok_or_else(|| "device 字段必须是对象".to_string())?;
    let fields = map
        .iter()
        .filter_map(|(key, value)| match value {
            serde_json::Value::String(text) => Some((key.clone(), text.clone())),
            serde_json::Value::Number(number) => Some((key.clone(), number.to_string())),
            _ => None,
        })
        .collect();
    Ok(DeviceProfile::from_owned_fields(fields, hg_signer::device::video_ua()))
}
