/**
 * 把已注册的设备身份打印成一行 JSON，供 Python 侧（hg/metasec.py）取用。
 *
 * 为什么单独一个脚本：device_register.cjs 本身只暴露 identity()/register()，
 * 而服务端现在要用 7.4.3.32 的 MetaSec 签名（hg-signer），签名必须带「已注册
 * 的 iid + device_id」以及注册时下发的 cookie，否则上游一律回 200 + 0 字节。
 *
 * 用法：node identity.cjs [--force]
 * 输出：{"device_id":"...","install_id":"...","cookies":"install_id=...; ttreq=..."}
 */

const { identity } = require('./device_register.cjs');

const force = process.argv.includes('--force');

function cookieString(cookies) {
  if (!cookies) return '';
  if (typeof cookies === 'string') return cookies;
  return Object.entries(cookies)
    .map(([key, value]) => `${key}=${value}`)
    .join('; ');
}

identity({ force })
  .then((data) => {
    process.stdout.write(
      JSON.stringify({
        device_id: String(data.device_id || ''),
        install_id: String(data.install_id || ''),
        cookies: cookieString(data.cookies),
      }) + '\n',
    );
  })
  .catch((error) => {
    process.stderr.write(`identity: ${error && error.message ? error.message : error}\n`);
    process.exit(1);
  });