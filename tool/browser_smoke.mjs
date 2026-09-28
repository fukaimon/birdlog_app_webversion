// Isolated real-Chrome smoke test; no personal browser profile is used.
// Run after build_pwa.py. Node >= 22, local Google Chrome required.
import {createServer} from 'node:http';
import {readFile, mkdtemp, writeFile} from 'node:fs/promises';
import {join, extname, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';

const root = resolve('build/web');
const profile = await mkdtemp(join(tmpdir(), 'birdlog-web-smoke-'));
const mime = {'.html':'text/html', '.js':'text/javascript', '.json':'application/json',
  '.wasm':'application/wasm', '.png':'image/png', '.otf':'font/otf', '.ttf':'font/ttf'};
const index = await readFile(join(root, 'index.html'), 'utf8');
const base = index.match(/<base href="([^"]+)"/)[1];
const server = createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  if (!path.startsWith(base)) {res.writeHead(404).end(); return;}
  const relative = path.slice(base.length) || 'index.html';
  const filename = resolve(root, relative);
  if (!filename.startsWith(root + '/')) {res.writeHead(403).end(); return;}
  try {
    const body = await readFile(filename);
    res.writeHead(200, {'Content-Type':mime[extname(filename)] || 'application/octet-stream',
      'Cache-Control':'no-cache'}).end(body);
  } catch {res.writeHead(404).end();}
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}${base}`;
const chromePath = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const chrome = spawn(chromePath, ['--headless=new', '--remote-debugging-port=0',
  `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', 'about:blank'],
  {stdio:['ignore', 'ignore', 'pipe']});
let socket;
let nextId = 0;
const pending = new Map();
const failures = [];
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++nextId;
  const timeout = setTimeout(() => {pending.delete(id); reject(new Error(`Timeout: ${method}`));}, 120000);
  pending.set(id, {resolve, reject, timeout});
  socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
});
const wait = ms => new Promise(r => setTimeout(r, ms));
async function until(check, message, timeout = 60000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    try {if (await check()) return;} catch {}
    await wait(250);
  }
  throw new Error(`Timed out: ${message}`);
}
try {
  const endpoint = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Chrome did not start')), 20000);
    let stderr = '';
    chrome.stderr.on('data', chunk => {
      stderr += chunk;
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) {clearTimeout(timeout); resolve(match[1]);}
    });
    chrome.on('error', reject);
    chrome.on('exit', code => reject(new Error(`Chrome exited: ${code}\n${stderr}`)));
  });
  socket = new WebSocket(endpoint);
  await new Promise((resolve, reject) => {socket.onopen = resolve; socket.onerror = reject;});
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const item = pending.get(message.id); pending.delete(message.id); clearTimeout(item.timeout);
      if (message.error) item.reject(new Error(JSON.stringify(message.error)));
      else item.resolve(message.result);
    } else if (message.method === 'Runtime.exceptionThrown') {
      failures.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
    }
  };
  const target = await send('Target.createTarget', {url:'about:blank'});
  const {sessionId} = await send('Target.attachToTarget', {targetId:target.targetId, flatten:true});
  const cdp = (method, params) => send(method, params, sessionId);
  const evaluate = async expression => {
    const result = await cdp('Runtime.evaluate', {expression, awaitPromise:true, returnByValue:true});
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || 'Evaluation failed');
    return result.result.value;
  };
  await cdp('Runtime.enable');
  await cdp('Network.enable');
  await cdp('Page.enable');
  await cdp('Emulation.setDeviceMetricsOverride', {width:393, height:852, deviceScaleFactor:1, mobile:true});
  await cdp('Page.navigate', {url});
  await until(() => evaluate("!!document.querySelector('flutter-view')"), 'Flutter view');
  await until(() => evaluate("navigator.serviceWorker.getRegistration().then(r => !!r?.active)"), 'offline preparation', 120000);
  await until(() => evaluate("!document.getElementById('startup')"), 'Flutter initialization');
  await evaluate("document.querySelector('flt-semantics-placeholder')?.click()");
  await until(() => evaluate("document.body.innerText.includes('新しく始める')"), 'cover UI');
  console.log('PASS: mobile UI and service worker installed');
  const invoke = async (command, payload = null) => evaluate(
    `birdlogStorage(${JSON.stringify(command)}, ${JSON.stringify(JSON.stringify(payload))}).then(JSON.parse)`);
  const start = '2026-09-27T09:00:00.000';
  const trip = {id:'smoke-trip', startedAt:start, title:'テスト観察地', startTime:'09:00', endTime:''};
  const bird = {id:'smoke-bird', tripId:trip.id, species:'スズメ', count:'3', time:start,
    latitude:35, longitude:139, locationAccuracy:10, comment:'テスト用データ', speciesOnly:false};
  await invoke('write', [
    {store:'trips', put:[trip], delete:[]}, {store:'records', put:[bird], delete:[]},
  ]);
  assert.equal((await invoke('read', 'records'))[0].species, 'スズメ');
  // Invalid row in a later store must roll back a valid update in the first.
  await assert.rejects(() => invoke('write', [
    {store:'records', put:[{...bird, count:'99'}], delete:[]},
    {store:'trips', put:[{title:'missing key'}], delete:[]},
  ]));
  assert.equal((await invoke('read', 'records'))[0].count, '3');
  console.log('PASS: IndexedDB multi-store atomic rollback');
  const secondTarget = await send('Target.createTarget', {url});
  const second = await send('Target.attachToTarget', {targetId:secondTarget.targetId, flatten:true});
  await until(async () => {
    const result = await send('Runtime.evaluate', {expression:
      "typeof birdlogStorage === 'function' && birdlogStorage('open','null').then(() => false, () => true)",
      awaitPromise:true, returnByValue:true}, second.sessionId);
    return result.result.value === true;
  }, 'second tab must be rejected');
  await send('Target.closeTarget', {targetId:secondTarget.targetId});
  console.log('PASS: simultaneous writer protection');
  await cdp('Network.emulateNetworkConditions', {offline:true, latency:0, downloadThroughput:0, uploadThroughput:0});
  await cdp('Page.reload', {ignoreCache:false});
  await until(() => evaluate("!document.getElementById('startup') && !!document.querySelector('flutter-view')"), 'offline Flutter restart');
  await evaluate("document.querySelector('flt-semantics-placeholder')?.click()");
  await until(() => evaluate("document.body.innerText.includes('新しく始める')"), 'offline cover UI');
  assert.equal((await invoke('read', 'records'))[0].comment, bird.comment);
  console.log('PASS: offline reload and persisted records');
  const shot = await cdp('Page.captureScreenshot', {format:'png'});
  await writeFile(resolve('build/browser-smoke.png'), Buffer.from(shot.data, 'base64'));
  assert.deepEqual(failures, [], 'uncaught JavaScript errors');
  console.log('PASS: screenshot build/browser-smoke.png');
  console.log('ALL BROWSER CHECKS PASSED');
} finally {
  socket?.close();
  chrome.kill();
  server.close();
  for (const item of pending.values()) clearTimeout(item.timeout);
}
