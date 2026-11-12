/*
 * 红果匿名设备注册（对齐 hongguoTV DeviceRegister.kt，2026-11 实测可用）。
 *
 * 为什么需要：上游内容接口按「服务端注册过的 device_id + install_id」放行，
 * 未注册设备访问 /novel/player/video_model/v1/ 一律 HTTP 200 + 0 字节
 * （搜索接口同样）。注册是匿名的：不带账号、不带签名头，body 是
 * ttEncrypt(gzip(JSON))，响应下发 device_id / install_id / device_token。
 *
 * 身份落盘复用：默认写到 HG_DB 同目录的 device.json（k8s 里是 PVC /app/data），
 * 可用 HG_DEVICE_FILE 覆盖；文件损坏或过期会重新注册。
 */
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const HOST = 'https://log5-applog-lf.fqnovel.com';
const PATH = '/service/2/device_register/';
const QUERY = '?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1';
const MAGIC = Buffer.from('746305100000', 'hex');
const KDF_SALT = Buffer.from(
  '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524'
  + 'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58', 'hex');
const APP_UA = 'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)';
// 注册身份一般长期有效；超过这个时长先复用、失败再重注册，避免每次冷启动都打注册接口。
const TTL_MS = 30 * 24 * 3600 * 1000;

const sha512 = (b) => crypto.createHash('sha512').update(b).digest();
const md5 = (b) => crypto.createHash('md5').update(b).digest();

function ttEncrypt(data) {
  const rnd = crypto.randomBytes(32);
  const derived = sha512(Buffer.concat([sha512(rnd), KDF_SALT]));
  const body = Buffer.concat([sha512(data), data]);
  const padLen = 16 - (body.length % 16);
  const padded = Buffer.concat([body, Buffer.alloc(padLen, padLen)]);
  const cipher = crypto.createCipheriv('aes-128-cbc', derived.subarray(0, 16), derived.subarray(16, 32));
  cipher.setAutoPadding(false);
  return Buffer.concat([MAGIC, rnd, cipher.update(padded), cipher.final()]);
}

function payload(device, now) {
  const uuid = () => crypto.randomUUID();
  const pick = (key, fallback) => (device[key] && String(device[key]).trim()) || fallback;
  const header = {
    display_name: '红果免费短剧', update_version_code: 73932, manifest_version_code: 73932,
    app_version_minor: '7.3.9.32', aid: 8662, channel: pick('channel', '69310258a'),
    package: 'com.phoenix.read', app_version: '7.3.9.32', version_code: 73932,
    sdk_version: '3.7.0-rc.34-fanqie-xiaoshuo', sdk_target_version: 29, git_hash: '3a88f4e',
    // os_version 必须是字符串：写成数字服务端直接回 device_id=0
    os: 'Android', os_version: pick('os_version', '12'),
    os_api: Number.parseInt(pick('os_api', '32'), 10) || 32,
    device_model: pick('device_type', 'AOSP on Intel Platform'),
    device_brand: pick('device_brand', 'SAMSUNG'), device_manufacturer: pick('device_brand', 'Intel'),
    cpu_abi: pick('host_abi', 'arm64-v8a'), release_build: 'b5e187f',
    density_dpi: Number.parseInt(pick('dpi', '360'), 10) || 360, display_density: 'mdpi',
    resolution: pick('resolution', '1440x2560').replace('*', 'x'),
    language: 'zh', timezone: 8, access: 'wifi', not_request_sender: 0,
    carrier: 'CHINA MOBILE', mcc_mnc: '46000', rom: 'eng.root.20231116.160340',
    rom_version: pick('rom_version', 'W528JS release-keys'), cdid: uuid(),
    // sig_hash 是安装包签名指纹；平台不校验一致性，但缺了会拒
    sig_hash: '56a962410c494bbaf0b58dba20cae56f',
    openudid: uuid().replace(/-/g, '').slice(0, 16), clientudid: uuid(),
    ipv6_list: [], region: 'CN', tz_name: 'Asia/Shanghai', tz_offset: 28800, sim_region: 'cn',
    sim_serial_number: [], oaid_may_support: false, req_id: uuid(), device_platform: 'android',
    custom: { account_region_src: 'fallback', host_bit: 64, account_region: 'cn', dragon_device_type: 'pad' },
    pre_installed_channel: '', apk_first_install_time: now, is_system_app: 0,
    sdk_flavor: 'china', guest_mode: 0,
  };
  return zlib.gzipSync(Buffer.from(JSON.stringify({ magic_tag: 'ss_app_log', header, _gen_time: now })));
}

function parse(body, setCookies = []) {
  let json = null;
  try { json = JSON.parse(body.replace(/^\uFEFF/, '')); } catch { return null; }
  const device = String(json.device_id_str || json.device_id || '').trim();
  const install = String(json.install_id_str || json.install_id || '').trim();
  if (!device || !install || device === '0' || install === '0') return null;
  const cookies = {};
  for (const header of setCookies) {
    const pair = String(header).split(';')[0].trim();
    if (!pair.includes('=')) continue;
    const name = pair.slice(0, pair.indexOf('=')).trim();
    const value = pair.slice(pair.indexOf('=') + 1).trim();
    if (name && value) cookies[name] = value;
  }
  return { device_id: device, install_id: install, device_token: json.device_token || '', cookies, at: Date.now() };
}

function deviceFile() {
  if (process.env.HG_DEVICE_FILE) return process.env.HG_DEVICE_FILE;
  const db = process.env.HG_DB || '/app/data/hongguo.db';
  return path.join(path.dirname(db), 'device.json');
}

function readCache() {
  try {
    const data = JSON.parse(fs.readFileSync(deviceFile(), 'utf8'));
    if (data && data.device_id && data.install_id && data.device_id !== '0') return data;
  } catch { /* 没有缓存或损坏 */ }
  return null;
}

function writeCache(identity) {
  const target = deviceFile();
  try {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    const tmp = `${target}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(identity), { mode: 0o600 });
    fs.renameSync(tmp, target);
  } catch (e) {
    console.error(`device.json 写入失败: ${e.message}`);
  }
}

async function register(device = {}) {
  const now = Date.now();
  const body = ttEncrypt(payload(device, now));
  const res = await fetch(HOST + PATH + QUERY, {
    method: 'POST',
    headers: {
      'User-Agent': APP_UA,
      'Content-Type': 'application/octet-stream;tt-data=a',
      'log-encode-type': 'gzip',
      'x-ss-dp': '8662',
      'x-ss-req-ticket': String(now),
      'x-vc-bdturing-sdk-version': '4.0.3.cn',
      lc: '101',
      'sdk-version': '2',
      'passport-sdk-version': '5051452',
      'x-neptune': '-8|50:51:59:30:40:47:49:39',
      'x-ss-stub': md5(body).toString('hex').toUpperCase(),
    },
    body,
  });
  const text = await res.text();
  const identity = parse(text, typeof res.headers.getSetCookie === 'function' ? res.headers.getSetCookie() : []);
  if (!identity) throw new Error(`device_register 被拒: HTTP ${res.status} ${text.slice(0, 200)}`);
  writeCache(identity);
  return identity;
}

/**
 * 取可用设备身份：优先落盘缓存（30 天内），force 时强制重注册。
 * 注册失败但有旧缓存时退回旧缓存，避免注册接口抖动直接把取流打挂。
 * 并发首次请求共用同一次注册，避免一个 pod 连打多次注册接口。
 */
let inflight = null;

async function identity({ force = false, device = {} } = {}) {
  const cached = readCache();
  if (cached && !force && Date.now() - Number(cached.at || 0) < TTL_MS) return cached;
  if (inflight) return inflight;
  const run = (async () => {
    try {
      return await register(device);
    } catch (e) {
      if (cached) {
        console.error(`device_register 失败，沿用旧身份: ${e.message}`);
        return cached;
      }
      throw e;
    }
  })();
  inflight = run;
  try {
    return await run;
  } finally {
    if (inflight === run) inflight = null;
  }
}

module.exports = { identity, register, parse, ttEncrypt, deviceFile };