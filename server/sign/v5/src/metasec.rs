//! 红果 7.4.3.32 的 MetaSec 应用层：材料装载、SDI token 交换、签名请求组装。
//!
//! 移植自 `hongguo-desktop` 的 `crates/hongguo-api/src/metasec/`（同一套 APK 7.4.3.32 逆向结论），
//! 只把 reqwest/tokio 换成同步实现：HTTP 全部交给 Python 侧，本模块只负责编解码与签名。

use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use aes::cipher::{BlockCipherDecrypt, BlockCipherEncrypt, KeyInit};
use aes::Aes128;
use flate2::read::{DeflateDecoder, ZlibDecoder};
use flate2::write::ZlibEncoder;
use flate2::Compression;

use crate::device::{anonymous_cookie, device_proto, fingerprint_for_cdid, DeviceProfile};
use crate::medusa_v5::{
    advance_ladon, Field13, License, RequestContext, RequestEntropy, RequestSigner, LICENSE_CHANNEL,
    SDK_VERSION, SDK_VERSION_CODE,
};
use crate::primitives::zigzag;
use crate::protobuf::{read_field, varint, WireValue};

// ---------------------------------------------------------------- 材料

/// APK 7.4.3.32 两段压缩材料的字节数（缓存文件 = DEX 段 ‖ ELF 段）。
pub const DEX_PART_LEN: usize = 3_915_212;
pub const ELF_PART_LEN: usize = 1_497_823;
pub const DEX_UNPACKED: usize = 10_417_728;
pub const ELF_UNPACKED: usize = 4_501_136;
pub const LICENSE_OFFSET: usize = 1_936_053;
pub const LICENSE_LENGTH: usize = 304;

/// 装载好的签名材料：field13 镜像解释器 + 许可证密钥。
pub struct Materials {
    pub signer: RequestSigner,
    pub dex: Vec<u8>,
    pub elf: Vec<u8>,
}

impl Materials {
    /// 从缓存文件装载（`dex_part ‖ elf_part`，每段是 raw deflate）。
    pub fn load(path: &Path) -> Result<Self, String> {
        let raw = std::fs::read(path).map_err(|error| format!("读取材料缓存失败: {error}"))?;
        if raw.len() != DEX_PART_LEN + ELF_PART_LEN {
            return Err(format!(
                "材料缓存长度异常: {}（期望 {}）",
                raw.len(),
                DEX_PART_LEN + ELF_PART_LEN
            ));
        }
        Self::from_parts(&raw[..DEX_PART_LEN], &raw[DEX_PART_LEN..])
    }

    /// 从两段压缩材料构建，并写入缓存文件。
    pub fn build(dex_part: &[u8], elf_part: &[u8], cache: Option<&Path>) -> Result<Self, String> {
        let materials = Self::from_parts(dex_part, elf_part)?;
        if let Some(path) = cache {
            let mut raw = Vec::with_capacity(DEX_PART_LEN + ELF_PART_LEN);
            raw.extend_from_slice(dex_part);
            raw.extend_from_slice(elf_part);
            std::fs::write(path, raw).map_err(|error| format!("写材料缓存失败: {error}"))?;
        }
        Ok(materials)
    }

    fn from_parts(dex_part: &[u8], elf_part: &[u8]) -> Result<Self, String> {
        let dex = inflate(dex_part, DEX_UNPACKED, "DEX")?;
        let elf = inflate(elf_part, ELF_UNPACKED, "ELF")?;
        let license = dex
            .get(LICENSE_OFFSET..LICENSE_OFFSET + LICENSE_LENGTH)
            .ok_or("DEX 里没有许可证段")?;
        let license = std::str::from_utf8(license).map_err(|_| "许可证不是 UTF-8")?;
        let license = License::decode(license).ok_or("许可证解码失败")?;
        let image = Field13::from_image(elf.clone()).map_err(|error| format!("F13 镜像无效: {error}"))?;
        Ok(Self {
            signer: RequestSigner::new(image, license),
            dex,
            elf,
        })
    }

    pub fn codec(&self) -> SdiCodec<'_> {
        SdiCodec {
            common_key: self.signer.common_key(),
            inner_key: self.signer.image().sdi_inner_key(),
        }
    }

    pub fn image(&self) -> &Field13 {
        self.signer.image()
    }
}

fn inflate(part: &[u8], expected: usize, name: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(expected);
    DeflateDecoder::new(part)
        .take(expected as u64 + 1)
        .read_to_end(&mut out)
        .map_err(|error| format!("{name} 解压失败: {error}"))?;
    if out.len() != expected {
        return Err(format!("{name} 解压长度异常: {}（期望 {expected}）", out.len()));
    }
    Ok(out)
}

// ---------------------------------------------------------------- SDI

const MAX_PLAINTEXT: usize = 64 * 1024;
const REQUEST_MAGIC: u64 = 0x2020_0422 << 1;
const RESPONSE_MAGIC: u64 = 0x2012_0312 << 1;
const IV_TAIL: [u8; 4] = 0x2020_0427_u32.to_le_bytes();
const XTEA_DELTA: u32 = 0x9e37_79b9;

pub struct SdiCodec<'a> {
    pub common_key: &'a [u8; 32],
    pub inner_key: [u8; 16],
}

pub struct Entropy {
    pub nonce: [u8; 4],
    pub frame_head: u8,
}

pub struct SdiToken {
    pub value: String,
    pub status: i64,
}

impl SdiCodec<'_> {
    pub fn encode_request(
        &self,
        plaintext: &[u8],
        millis: u64,
        entropy: Entropy,
    ) -> Result<Vec<u8>, String> {
        if plaintext.len() > MAX_PLAINTEXT || millis > u64::MAX / 2 {
            return Err(invalid_sdi());
        }
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(plaintext).map_err(|_| invalid_sdi())?;
        let mut compressed = encoder.finish().map_err(|_| invalid_sdi())?;
        // SDI 的 DEFLATE 外壳用 FLEVEL=0 的 32 KiB 窗口。
        if compressed.len() < 2 || compressed[0] != 0x78 {
            return Err(invalid_sdi());
        }
        compressed[1] = 0x01;
        let mut container = (plaintext.len() as u32).to_le_bytes().to_vec();
        container.extend_from_slice(&compressed);
        let ciphertext = self.encrypt(&container, entropy);
        let mut packet = Vec::new();
        append_number(&mut packet, 1, REQUEST_MAGIC);
        append_number(&mut packet, 2, 2);
        append_number(&mut packet, 3, 2);
        append_bytes(&mut packet, 4, &ciphertext);
        append_number(&mut packet, 5, millis * 2);
        Ok(packet)
    }

    pub fn decode_response(&self, packet: &[u8]) -> Result<SdiToken, String> {
        let ciphertext = response_ciphertext(packet)?;
        let plaintext = self
            .decrypt(ciphertext)
            .map_err(|_| "MetaSec SDI 响应解密失败".to_string())?;
        let (token, status) = decode_token_fields(&plaintext)?;
        if !matches!(status, 200 | 202) {
            return Err(format!("MetaSec SDI token status {status}"));
        }
        let value = token.ok_or_else(|| format!("MetaSec SDI token status {status} 没有 token"))?;
        Ok(SdiToken {
            value: value.to_owned(),
            status,
        })
    }

    fn encrypt(&self, container: &[u8], entropy: Entropy) -> Vec<u8> {
        let padding = (8 - container.len() % 8) & 7;
        let start = 1 + (padding.wrapping_sub(1) & 3);
        let end = start + container.len();
        let mut frame = vec![0; container.len() + 8 + padding];
        frame[0] = entropy.frame_head & 0xf8 | padding as u8;
        frame[start..end].copy_from_slice(container);
        let offset = if start >= 3 { 1 } else { end };
        frame[offset..offset + 2].copy_from_slice(&crc16(container).to_be_bytes());
        Xtea::new(self.inner_key, entropy.nonce).encrypt_cbc(&mut frame);
        let mut outer = Vec::with_capacity(frame.len() + 21);
        // 原生解码器校验首字节与首个 XTEA 字节的整字节异或。
        outer.push(frame[0] ^ 3);
        outer.extend(frame);
        outer.extend(entropy.nonce);
        aes_encrypt(outer, self.common_key)
    }

    fn decrypt(&self, ciphertext: &[u8]) -> Result<Vec<u8>, String> {
        let outer = aes_decrypt(ciphertext, self.common_key)?;
        if outer.len() < 13 || (outer.len() - 5) % 8 != 0 || outer[0] ^ outer[1] != 3 {
            return Err(invalid_sdi());
        }
        let last = outer.len() - 4;
        let nonce: [u8; 4] = outer[last..].try_into().map_err(|_| invalid_sdi())?;
        let mut frame = outer[1..last].to_vec();
        Xtea::new(self.inner_key, nonce).decrypt_cbc(&mut frame);
        inflate_frame(&frame)
    }
}

fn response_ciphertext(mut packet: &[u8]) -> Result<&[u8], String> {
    let mut magic = None;
    let mut version = None;
    let mut cipher = None;
    let mut status = None;
    while !packet.is_empty() {
        match read_field(&mut packet).ok_or_else(invalid_sdi)? {
            (1, WireValue::Varint(value)) if magic.is_none_or(|previous| previous == value) => {
                magic = Some(value)
            }
            (2, WireValue::Varint(value)) if version.is_none_or(|previous| previous == value) => {
                version = Some(value)
            }
            (3, WireValue::Varint(value)) => status = Some(value),
            (6, WireValue::Bytes(value)) if cipher.is_none() => cipher = Some(value),
            (1 | 2 | 6, _) => return Err(invalid_sdi()),
            _ => {}
        }
    }
    if magic != Some(RESPONSE_MAGIC) || version != Some(2) {
        return Err("MetaSec SDI 响应信封无效".to_string());
    }
    cipher.ok_or_else(|| match status {
        Some(code) => format!(
            "MetaSec SDI 拒绝换取 token ({})",
            (code >> 1) as i64 ^ -((code & 1) as i64)
        ),
        None => "MetaSec SDI 响应缺少 token 字段".to_string(),
    })
}

fn decode_token_fields(mut plaintext: &[u8]) -> Result<(Option<&str>, i64), String> {
    let mut token = None;
    let mut status = None;
    while !plaintext.is_empty() {
        match read_field(&mut plaintext).ok_or_else(invalid_sdi)? {
            (1, WireValue::Bytes(value)) if token.is_none() => {
                if value.len() > 256 {
                    return Err(invalid_sdi());
                }
                token = Some(std::str::from_utf8(value).map_err(|_| invalid_sdi())?);
            }
            (2, WireValue::Varint(value)) if status.is_none() => {
                status = Some((value >> 1) as i64 ^ -((value & 1) as i64));
            }
            (1 | 2, _) => return Err(invalid_sdi()),
            _ => {}
        }
    }
    Ok((
        token.filter(|value| !value.is_empty()),
        status.ok_or_else(|| "MetaSec SDI 响应缺少 token status".to_string())?,
    ))
}

fn inflate_frame(frame: &[u8]) -> Result<Vec<u8>, String> {
    let padding = usize::from(frame[0] & 7);
    let start = 1 + (padding.wrapping_sub(1) & 3);
    let length = frame
        .len()
        .checked_sub(8 + padding)
        .ok_or_else(invalid_sdi)?;
    let container = frame.get(start..start + length).ok_or_else(invalid_sdi)?;
    let (expected, compressed) = container.split_at_checked(4).ok_or_else(invalid_sdi)?;
    let expected = u32::from_le_bytes(expected.try_into().map_err(|_| invalid_sdi())?) as usize;
    if expected > MAX_PLAINTEXT {
        return Err(invalid_sdi());
    }
    let mut plain = Vec::with_capacity(expected);
    ZlibDecoder::new(compressed)
        .take(expected as u64 + 1)
        .read_to_end(&mut plain)
        .map_err(|_| invalid_sdi())?;
    if plain.len() != expected {
        return Err(invalid_sdi());
    }
    Ok(plain)
}

struct Xtea {
    words: [u32; 4],
    rounds: u32,
    iv: [u8; 8],
}

impl Xtea {
    fn new(key: [u8; 16], nonce: [u8; 4]) -> Self {
        let words =
            std::array::from_fn(|i| u32::from_be_bytes(key[i * 4..i * 4 + 4].try_into().unwrap()));
        let rounds = 32 + 8 * (u32::from_le_bytes(nonce) % 5);
        let mut iv = [0; 8];
        iv[..4].copy_from_slice(&nonce);
        iv[4..].copy_from_slice(&IV_TAIL);
        Self { words, rounds, iv }
    }

    fn encrypt_cbc(&self, data: &mut [u8]) {
        let mut previous = self.iv;
        for block in data.as_chunks_mut::<8>().0 {
            block
                .iter_mut()
                .zip(previous)
                .for_each(|(byte, mask)| *byte ^= mask);
            let (mut left, mut right) = read_block(block);
            let mut sum: u32 = 0;
            for _ in 0..self.rounds {
                left = left.wrapping_add(self.mix(right, sum, sum));
                sum = sum.wrapping_add(XTEA_DELTA);
                right = right.wrapping_add(self.mix(left, sum, sum >> 11));
            }
            write_block(block, left, right);
            previous.copy_from_slice(block);
        }
    }

    fn decrypt_cbc(&self, data: &mut [u8]) {
        let mut previous = self.iv;
        for block in data.as_chunks_mut::<8>().0 {
            let cipher = *block;
            let (mut left, mut right) = read_block(block);
            let mut sum = self.rounds.wrapping_mul(XTEA_DELTA);
            for _ in 0..self.rounds {
                right = right.wrapping_sub(self.mix(left, sum, sum >> 11));
                sum = sum.wrapping_sub(XTEA_DELTA);
                left = left.wrapping_sub(self.mix(right, sum, sum));
            }
            write_block(block, left, right);
            block
                .iter_mut()
                .zip(previous)
                .for_each(|(byte, mask)| *byte ^= mask);
            previous = cipher;
        }
    }

    fn mix(&self, value: u32, sum: u32, index: u32) -> u32 {
        ((value << 4) ^ (value >> 5)).wrapping_add(value)
            ^ sum.wrapping_add(self.words[(index & 3) as usize])
    }
}

fn read_block(block: &[u8]) -> (u32, u32) {
    (
        u32::from_be_bytes(block[..4].try_into().expect("8-byte block")),
        u32::from_be_bytes(block[4..].try_into().expect("8-byte block")),
    )
}

fn write_block(block: &mut [u8], left: u32, right: u32) {
    block[..4].copy_from_slice(&left.to_be_bytes());
    block[4..].copy_from_slice(&right.to_be_bytes());
}

fn aes_encrypt(mut data: Vec<u8>, key: &[u8; 32]) -> Vec<u8> {
    let (cipher, mut previous) = aes_parts(key);
    let padding = 16 - data.len() % 16;
    data.extend(std::iter::repeat_n(padding as u8, padding));
    for block in data.as_chunks_mut::<16>().0 {
        block
            .iter_mut()
            .zip(previous)
            .for_each(|(byte, mask)| *byte ^= mask);
        cipher.encrypt_block(block.into());
        previous.copy_from_slice(block);
    }
    data
}

fn aes_decrypt(data: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, String> {
    if data.is_empty() || data.len() > MAX_PLAINTEXT * 2 || data.len() % 16 != 0 {
        return Err(invalid_sdi());
    }
    let (cipher, mut previous) = aes_parts(key);
    let mut plaintext = data.to_vec();
    for (source, block) in data
        .as_chunks::<16>()
        .0
        .iter()
        .zip(plaintext.as_chunks_mut::<16>().0)
    {
        cipher.decrypt_block(block.into());
        block
            .iter_mut()
            .zip(previous)
            .for_each(|(byte, mask)| *byte ^= mask);
        previous.copy_from_slice(source);
    }
    let padding = usize::from(*plaintext.last().ok_or_else(invalid_sdi)?);
    if !(1..=16).contains(&padding)
        || plaintext
            .iter()
            .rev()
            .take(padding)
            .any(|byte| usize::from(*byte) != padding)
    {
        return Err(invalid_sdi());
    }
    plaintext.truncate(plaintext.len() - padding);
    Ok(plaintext)
}

fn aes_parts(key: &[u8; 32]) -> (Aes128, [u8; 16]) {
    let (key, iv) = key.split_at(16);
    (
        Aes128::new(key.try_into().expect("16-byte AES key")),
        iv.try_into().expect("16-byte AES IV"),
    )
}

fn crc16(bytes: &[u8]) -> u16 {
    let mut crc = 0u16;
    for byte in bytes {
        crc ^= u16::from(*byte) << 8;
        for _ in 0..8 {
            let high = crc & 0x8000 != 0;
            crc <<= 1;
            if high {
                crc ^= 0x1021;
            }
        }
    }
    crc
}

fn invalid_sdi() -> String {
    "MetaSec SDI 报文无效".to_string()
}

pub fn append_bytes(output: &mut Vec<u8>, field: u32, bytes: &[u8]) {
    output.extend(varint(u64::from(field) << 3 | 2));
    output.extend(varint(bytes.len() as u64));
    output.extend_from_slice(bytes);
}

pub fn append_number(output: &mut Vec<u8>, field: u32, value: u64) {
    output.extend(varint(u64::from(field) << 3));
    output.extend(varint(value));
}

pub fn append_signed(output: &mut Vec<u8>, field: u32, value: i64) {
    append_number(output, field, zigzag(value) as u64);
}

// ---------------------------------------------------------------- SDI 明文

const UNAVAILABLE: i64 = -999_999;
const SDI_UNAVAILABLE_TEXT: &[u32] = &[
    1, 19, 20, 23, 28, 31, 32, 38, 39, 50, 53, 93, 94, 95, 96, 109, 110, 111, 115, 135, 2000, 2001,
];
const SDI_UNAVAILABLE_NUMBER: &[u32] = &[
    13, 29, 30, 36, 37, 41, 42, 43, 49, 51, 52, 56, 57, 58, 59, 60, 61, 62, 63, 64, 66, 67, 69, 70,
    71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 97, 98, 99, 100, 101,
    102, 103, 104, 105, 106, 113, 114, 116, 117, 118,
];

pub fn sdi_payload(device: &DeviceProfile, image: &Field13, token: Option<&str>) -> Vec<u8> {
    let marker = image.unavailable_string();
    let mut bytes = Vec::new();
    append_bytes(&mut bytes, 1, &sdi_device(device, marker));
    if let Some(token) = token {
        append_bytes(&mut bytes, 2, token.as_bytes());
    }
    append_bytes(&mut bytes, 3, device.get("device_platform").as_bytes());
    append_bytes(&mut bytes, 4, SDK_VERSION.as_bytes());
    append_signed(&mut bytes, 5, i64::from(SDK_VERSION_CODE));
    append_bytes(&mut bytes, 6, device.get("aid").as_bytes());
    append_bytes(&mut bytes, 7, device.get("version_name").as_bytes());
    append_bytes(&mut bytes, 8, device.get("device_id").as_bytes());
    append_signed(&mut bytes, 11, UNAVAILABLE);
    append_signed(&mut bytes, 16, UNAVAILABLE);
    append_bytes(&mut bytes, 17, marker.as_bytes());
    bytes
}

fn sdi_device(device: &DeviceProfile, marker: &str) -> Vec<u8> {
    enum Value<'a> {
        Number(i64),
        Text(&'a str),
    }
    let text = [
        (2, device.get("device_brand")),
        (3, device.get("device_type")),
        (5, "Android"),
        (6, device.get("os_version")),
        (7, device.get("resolution")),
        (9, rom_version(device)),
        (12, "Asia/Shanghai,8"),
        (26, boot_id()),
    ];
    let numeric = [(8, device.get("dpi")), (48, device.get("os_api"))];
    let mut fields: Vec<_> = SDI_UNAVAILABLE_TEXT
        .iter()
        .map(|field| (*field, Value::Text(marker)))
        .chain(
            SDI_UNAVAILABLE_NUMBER
                .iter()
                .map(|field| (*field, Value::Number(UNAVAILABLE))),
        )
        .chain(
            text.into_iter()
                .filter(|(_, value)| !value.is_empty())
                .map(|(field, value)| (field, Value::Text(value))),
        )
        .chain(
            numeric
                .into_iter()
                .map(|(field, value)| (field, Value::Number(value.parse().unwrap_or(UNAVAILABLE)))),
        )
        .collect();
    fields.sort_unstable_by_key(|(field, _)| *field);
    let mut bytes = Vec::new();
    for (field, value) in fields {
        match value {
            Value::Number(value) => append_signed(&mut bytes, field, value),
            Value::Text(value) => append_bytes(&mut bytes, field, value.as_bytes()),
        }
    }
    bytes
}

fn boot_id() -> &'static str {
    static BOOT_ID: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    BOOT_ID.get_or_init(|| {
        let raw = match std::env::consts::OS {
            "macos" => std::process::Command::new("/usr/sbin/sysctl")
                .args(["-n", "kern.bootsessionuuid"])
                .output()
                .ok()
                .filter(|result| result.status.success())
                .and_then(|result| String::from_utf8(result.stdout).ok()),
            "linux" | "android" => std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok(),
            _ => None,
        };
        raw.map(|value| value.trim().to_ascii_lowercase())
            .filter(|value| {
                value.len() == 36
                    && value
                        .bytes()
                        .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
            })
            .unwrap_or_default()
    })
}

pub fn rom_version(device: &DeviceProfile) -> &str {
    let version = device.get("rom_version");
    if version.is_empty() {
        return fingerprint_for_cdid(device.get("cdid")).rom_version;
    }
    version
}

pub fn signing_device(device: &DeviceProfile) -> Vec<u8> {
    let bytes = device_proto(device.get("cdid"), device.get("device_id"));
    let mut output = Vec::with_capacity(bytes.len());
    let mut source = bytes.as_slice();
    while !source.is_empty() {
        let start = source;
        let Some((field, wire)) = read_field(&mut source) else {
            break;
        };
        if (22, matches!(wire, WireValue::Bytes(_))) == (field, true) {
            append_bytes(&mut output, field, device.get("os_version").as_bytes());
        } else {
            output.extend_from_slice(&start[..start.len() - source.len()]);
        }
    }
    output
}

// ---------------------------------------------------------------- 签名

const SDI_ORIGIN: &str = "https://mssdk.zijieapi.com";
const SDI_PATH: &str = "/sdi/get_token";
const PLAY_FLAGS: u64 = 0x0504;
const SDI_FLAGS: u64 = 2;
const COLD_COUNTER: i64 = 694_367;
const SDK_ENVIRONMENT_CHANNEL: &[u8] = b"seo_laxin_pc_android";

const QUERY_FIELDS: &[&str] = &[
    "os",
    "ssmix",
    "_rticket",
    "cdid",
    "channel",
    "aid",
    "app_name",
    "version_code",
    "version_name",
    "manifest_version_code",
    "update_version_code",
    "resolution",
    "dpi",
    "device_type",
    "device_brand",
    "language",
    "os_api",
    "os_version",
    "ac",
    "host_abi",
    "dragon_device_type",
    "pv_player",
    "compliance_status",
    "need_personal_recommend",
    "player_so_load",
    "is_android_pad_screen",
    "rom_version",
    "iid",
    "device_id",
    "klink_egdi",
];

const SDI_PREFIX: &[&str] = &[
    "lc_id",
    "platform",
    "device_platform",
    "sdk_ver",
    "sdk_ver_code",
    "app_ver",
    "version_code",
    "aid",
    "sdkid",
    "subaid",
    "iid",
    "did",
    "bd_did",
    "client_type",
    "region_type",
    "mode",
    "full_update_version_code",
];

pub struct WireRequest<'a> {
    pub origin: &'a str,
    pub path: &'a str,
    pub ticket: u64,
    pub sdk: bool,
    pub body: Vec<u8>,
}

pub struct SignedRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// SDI token 交换请求（sdk=true 分支）。
pub fn sdi_request(
    materials: &Materials,
    device: &DeviceProfile,
    token: Option<&str>,
) -> Result<SignedRequest, String> {
    let codec = materials.codec();
    let ticket = now_millis()?;
    let body = codec.encode_request(
        &sdi_payload(device, materials.image(), token),
        ticket,
        Entropy {
            nonce: rand::random(),
            frame_head: rand::random(),
        },
    )?;
    let headers = vec![
        ("content-type".to_string(), "application/octet-stream".to_string()),
        ("accept".to_string(), "*/*".to_string()),
        ("x-tt-request-tag".to_string(), "t=0;n=0".to_string()),
        ("x-ss-dp".to_string(), device.get("aid").to_string()),
        ("cookie".to_string(), anonymous_cookie(device)),
    ];
    let request = WireRequest {
        origin: SDI_ORIGIN,
        path: SDI_PATH,
        ticket,
        sdk: true,
        body,
    };
    sign(materials, device, request, headers, token, &mut 0)
}

/// 播放取流请求签名（sdk=false 分支）。
pub fn playback_request(
    materials: &Materials,
    device: &DeviceProfile,
    origin: &str,
    path: &str,
    body: Vec<u8>,
    token: Option<&str>,
    ladon: &mut u32,
) -> Result<SignedRequest, String> {
    let ticket = now_millis()?;
    let request = WireRequest {
        origin,
        path,
        ticket,
        sdk: false,
        body,
    };
    sign(materials, device, request, Vec::new(), token, ladon)
}

fn sign(
    materials: &Materials,
    device: &DeviceProfile,
    request: WireRequest<'_>,
    mut headers: Vec<(String, String)>,
    token: Option<&str>,
    ladon: &mut u32,
) -> Result<SignedRequest, String> {
    let query = query(device, request.ticket, request.sdk);
    let khronos = (request.ticket / 1000) as u32;
    let url = format!("{}{}?{query}", request.origin, request.path);
    let state = SignatureState::new(device, request.ticket, token, request.sdk);
    let next = advance_ladon(*ladon, rand::random::<u64>() & !15, khronos);
    *ladon = next;
    let context = RequestContext {
        device_id: device.get("device_id"),
        version_name: device.get("version_name"),
        token,
        counters: &state.counters,
        environment: &state.environment,
        runtime_json: &state.runtime_json,
        flags: if request.sdk { SDI_FLAGS } else { PLAY_FLAGS },
        ladon: next,
    };
    let factors = materials
        .signer
        .factors(
            &query,
            Some(&request.body),
            khronos,
            &context,
            &RequestEntropy::draw(),
        )
        .map_err(|error| format!("签名失败: {error}"))?;
    headers.extend(factors);
    headers.extend([
        ("user-agent".to_string(), cronet_user_agent(device)),
        ("x-vc-bdturing-sdk-version".to_string(), "4.0.3.cn".to_string()),
        (
            "x-ss-stub".to_string(),
            crate::primitives::md5_hex_upper(&request.body),
        ),
        (
            "x-tt-trace-id".to_string(),
            format!(
                "00-{:032x}-{:016x}-01",
                rand::random::<u128>(),
                rand::random::<u64>()
            ),
        ),
    ]);
    if !request.sdk {
        headers.extend([
            (
                "content-type".to_string(),
                "application/json; charset=utf-8".to_string(),
            ),
            (
                "accept".to_string(),
                "application/json; charset=utf-8,application/x-protobuf".to_string(),
            ),
            ("x-xs-from-web".to_string(), "0".to_string()),
            ("sdk-version".to_string(), "2".to_string()),
            ("passport-sdk-version".to_string(), "5051452".to_string()),
            ("x-ss-req-ticket".to_string(), request.ticket.to_string()),
            (
                "x-reading-request".to_string(),
                format!("{}-{}", request.ticket, rand::random::<u32>()),
            ),
        ]);
    }
    Ok(SignedRequest {
        url,
        headers,
        body: request.body,
    })
}

fn query(device: &DeviceProfile, ticket: u64, sdk: bool) -> String {
    let ticket = ticket.to_string();
    let sdk_version_code = SDK_VERSION_CODE.to_string();
    let mut pairs: Vec<String> = Vec::new();
    let prefix: &[&str] = if sdk { SDI_PREFIX } else { &["device_platform"] };
    for key in prefix {
        let value = match *key {
            "lc_id" => LICENSE_CHANNEL,
            "platform" => "android",
            "sdk_ver" => SDK_VERSION,
            "sdk_ver_code" => &sdk_version_code,
            "app_ver" => device.get("version_name"),
            "did" => device.get("device_id"),
            "client_type" => "inhouse",
            "region_type" => "ml",
            "mode" => "2",
            "full_update_version_code" => device.get("update_version_code"),
            _ => device.get(key),
        };
        pairs.push(format!("{}={}", form_encode(key), form_encode(value)));
    }
    for key in QUERY_FIELDS {
        if sdk && matches!(*key, "aid" | "iid" | "version_code") {
            continue;
        }
        let value = match *key {
            "_rticket" => &ticket,
            "need_personal_recommend" => "1",
            "rom_version" => rom_version(device),
            _ => device.get(key),
        };
        pairs.push(format!("{}={}", form_encode(key), form_encode(value)));
    }
    let query = pairs.join("&");
    if sdk {
        query
    } else {
        query.replacen("&host_abi=", "&&host_abi=", 1)
    }
}

/// x-www-form-urlencoded 取值编码：`*`/`-`/`.`/`_` 原样，空格写 `+`。
fn form_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'*' | b'-' | b'.' | b'_' => {
                out.push(byte as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn cronet_user_agent(device: &DeviceProfile) -> String {
    let fingerprint = fingerprint_for_cdid(device.get("cdid"));
    format!(
        "com.phoenix.read/{} (Linux; U; Android {}; zh_CN; {}; Build/{}; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)",
        device.get("version_code"),
        fingerprint.os,
        fingerprint.display,
        fingerprint.build
    )
}

pub fn now_millis() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .map_err(|_| "系统时钟异常".to_string())
}

struct SignatureState {
    counters: Vec<u8>,
    environment: Vec<u8>,
    runtime_json: String,
}

impl SignatureState {
    fn new(device: &DeviceProfile, ticket: u64, token: Option<&str>, sdk: bool) -> Self {
        static SIGNED: AtomicU64 = AtomicU64::new(0);
        let count = SIGNED.fetch_add(1, Ordering::Relaxed) + 1;
        let mut counters = Vec::new();
        for (field, value) in [
            (1, count as i64),
            (2, COLD_COUNTER),
            (3, COLD_COUNTER),
            (5, COLD_COUNTER),
        ] {
            append_signed(&mut counters, field, value);
        }
        let mut environment = Vec::new();
        append_signed(&mut environment, 1, if sdk { 1 } else { count as i64 });
        append_bytes(&mut environment, 6, b"v04.10.03.04-bugfix");
        append_signed(&mut environment, 7, i64::from(std::process::id()));
        append_bytes(&mut environment, 8, SDK_ENVIRONMENT_CHANNEL);
        append_bytes(&mut environment, 12, &signing_device(device));
        append_bytes(&mut environment, 13, &[]);
        append_bytes(&mut environment, 14, device.get("version_name").as_bytes());
        append_signed(&mut environment, 15, 2114);
        append_signed(&mut environment, 19, ticket as i64);
        let runtime_json = serde_json::json!({
            "cmr": 16_777_216, "cmr2": 16_777_216, "vpn": 0,
            "kd": 0, "dyn": "", "do": 0, "tk": token.is_some()
        })
        .to_string();
        Self {
            counters,
            environment,
            runtime_json,
        }
    }
}