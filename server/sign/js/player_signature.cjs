// 真实 Gorgon/Argus/Ladon 签名（对齐 hongguoTV PlayerSignature.kt / Go 参考实现）
// 仅依赖 node:crypto（sm3 / md5 / aes-128-cbc）
const crypto = require('node:crypto');

const M64 = (1n << 64n) - 1n;
const md5 = (b) => crypto.createHash('md5').update(b).digest();
const sm3 = (b) => crypto.createHash('sm3').update(b).digest();
const hex = (s) => Buffer.from(s, 'hex');
const be32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(Number(n) & 0xffffffff); return b; };
const le64 = (n) => { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(n) & M64); return b; };
const word = (b, at) => b.readBigUInt64LE(at);
const rotr = (x, n) => ((x >> BigInt(n)) | (x << BigInt(64 - n))) & M64;
const rotl = (x, n) => ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64;
const pad = (b) => { const k = 16 - (b.length % 16); return Buffer.concat([b, Buffer.alloc(k, k)]); };
const hexs = (b) => b.toString('hex');

function varint(n) {
  let v = BigInt(n); const out = [];
  while (v >> 7n) { out.push(Number(v & 0x7fn) | 0x80); v >>= 7n; }
  out.push(Number(v)); return Buffer.from(out);
}

function proto(fields) {
  const parts = [];
  for (const [tag, value] of Object.entries(fields)) {
    const t = Number(tag);
    if (typeof value === 'number' || typeof value === 'bigint') {
      parts.push(varint(t << 3), varint(value));
    } else {
      const bytes = Buffer.isBuffer(value) ? value : Buffer.from(String(value));
      parts.push(varint((t << 3) | 2), varint(bytes.length), bytes);
    }
  }
  return Buffer.concat(parts);
}

function ladon(ts, salt) {
  const ascii = hexs(md5(Buffer.concat([salt, Buffer.from('8662')])));
  const asciiBuf = Buffer.from(ascii, 'binary'); // ASCII 字符串的字节，不是 hex 解码
  const queue = [word(asciiBuf, 16), word(asciiBuf, 24)];
  let left = word(asciiBuf, 0), right = word(asciiBuf, 8);
  const keys = [];
  for (let i = 0; i < 34; i += 1) {
    keys.push(left);
    const next = ((rotr(right, 8) + left) & M64) ^ BigInt(i);
    queue.push(next);
    left = next ^ rotl(left, 3);
    right = queue.shift();
  }
  const data = pad(Buffer.from(`${ts}-1611921764-8662`));
  const out = [Buffer.from(salt)];
  for (let at = 0; at < data.length; at += 16) {
    let a = word(data, at), b = word(data, at + 8);
    for (const k of keys) { b = k ^ ((a + rotr(b, 8)) & M64); a = b ^ rotl(a, 3); }
    out.push(le64(a), le64(b));
  }
  return Buffer.concat(out).toString('base64');
}

function argus(query, body, deviceId, ts, nonce) {
  const random = BigInt(nonce.readInt32LE(6) & 0x7fffffff);
  const nested = proto({ 1: 1, 2: 1, 3: 1, 7: 3348294860 });
  const environment = proto({ 1: '25053RT47C', 2: '16', 3: 'update_64', 4: 2147483648 });
  const message = proto({
    1: 0x40401252, 2: 2, 3: random, 4: '8662', 5: deviceId,
    6: '1611921764', 7: '7.3.5.32', 8: 'v04.07.01-ml-android', 9: 135135744,
    10: Buffer.alloc(8), 11: 0, 12: BigInt(ts) * 2n,
    13: sm3(body ? md5(body) : Buffer.alloc(16)).subarray(0, 6),
    14: sm3(Buffer.from(query)).subarray(0, 6),
    15: nested, 16: Buffer.alloc(0),
    20: 'none', 21: 738, 23: environment, 25: 2,
  });
  const secret = hex('ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c');
  const derived = sm3(Buffer.concat([secret, hex('3ccc567b'), secret]));
  const keys = [];
  for (let i = 0; i < 4; i += 1) keys[i] = word(derived, i * 8);
  const C = 0x3dc94c3a046d678bn;
  for (let i = 4; i < 72; i += 1) {
    const x = rotr(keys[i - 1], 3) ^ keys[i - 3];
    keys[i] = ((~keys[i - 4]) & M64) ^ x ^ rotr(x, 1) ^ ((C >> BigInt((i - 4) % 62)) & 1n) ^ 3n;
  }
  const blocks = pad(message);
  const enc = [];
  for (let at = 0; at < blocks.length; at += 16) {
    let a = word(blocks, at), b = word(blocks, at + 8);
    for (const k of keys) {
      const next = a ^ (rotl(b, 1) & rotl(b, 8)) ^ rotl(b, 2) ^ k;
      a = b; b = next;
    }
    enc.push(le64(a), le64(b));
  }
  const mask = hex('d04ffdffd04ffdff');
  const scrambled = Buffer.from(Buffer.concat(enc).map((b, i) => b ^ mask[i % 8]));
  const container = Buffer.concat([hex('a6e783ee7001100918'),
    Buffer.concat([mask, scrambled]).reverse(), hex('567b')]);
  const cipher = crypto.createCipheriv('aes-128-cbc', md5(secret.subarray(0, 16)), md5(secret.subarray(16, 32)));
  return Buffer.concat([hex('3ccc'), cipher.update(container), cipher.final()]).toString('base64');
}

function rev8(v) { let r = 0; for (let i = 0; i < 8; i += 1) r = (r << 1) | ((v >> i) & 1); return r & 255; }

/** 返回 X-Gorgon / X-Khronos / X-SS-Req-Ticket / X-Argus / X-Ladon（+ X-SS-STUB）。 */
function headers(query, body, deviceId, now, nonce = crypto.randomBytes(11)) {
  const ts = Math.floor(now / 1000);
  const input = Buffer.concat([
    md5(Buffer.from(query)).subarray(0, 4),
    body ? md5(body).subarray(0, 4) : Buffer.alloc(4),
    Buffer.alloc(4), hex('00060b1c'), be32(ts),
  ]);
  const key = hex('44b9b9d9a4aef9fca493aa757ca3c2c4a496938f');
  for (let i = 0; i < input.length; i += 1) input[i] ^= key[i];
  for (let i = 0; i < input.length; i += 1) {
    const v = input[i];
    const swapped = ((v << 4) | (v >> 4)) & 255;
    input[i] = rev8(swapped ^ input[(i + 1) % input.length]) ^ 0xeb;
  }
  const out = {
    'X-Gorgon': hexs(Buffer.concat([hex('8404401c0000'), input])),
    'X-Khronos': String(ts),
    'X-SS-Req-Ticket': String(now),
    'X-Argus': argus(query, body, deviceId, ts, nonce),
    'X-Ladon': ladon(ts, nonce.subarray(2, 6)),
  };
  if (body) out['X-SS-STUB'] = md5(body).toString('hex').toUpperCase();
  return out;
}

module.exports = { headers, md5, sm3, hex };