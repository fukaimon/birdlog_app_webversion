/* IndexedDB bridge. All requests settle at transaction completion, not put(). */
(() => {
  'use strict';
  // Retain legacy activity stores without reading/writing them, preserving existing databases.
  const stores = ['trips', 'records', 'bird_lists', 'stationary_sessions',
    'activities', 'activity_points', 'places'];
  let database;
  let releaseLock;
  const request = value => new Promise((resolve, reject) => {
    value.onsuccess = () => resolve(value.result);
    value.onerror = () => reject(value.error);
  });
  const complete = tx => new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onabort = () => reject(tx.error || new Error('Transaction aborted'));
    tx.onerror = () => {}; // onabort is the authoritative failure.
  });
  async function open() {
    if (database) return;
    if (!navigator.locks) throw new Error('Web Locks requires a modern HTTPS browser');
    // Prevent two tabs from independently recovering/editing the same sessions.
    await new Promise((resolve, reject) => {
      navigator.locks.request('birdlog_app_webversion:writer', {ifAvailable: true},
        async lock => {
          if (!lock) { reject(new Error('Already open in another tab')); return; }
          await new Promise(release => { releaseLock = release; resolve(); });
        }).catch(reject);
    });
    try {
      const opening = indexedDB.open('birdlog_app_webversion', 1);
      opening.onupgradeneeded = () => {
        const db = opening.result;
        for (const name of stores) {
          const store = db.createObjectStore(name, {keyPath: 'id'});
          if (name === 'activities') store.createIndex('trip', 'trip_id');
          if (name === 'activity_points') store.createIndex('session', 'session_id');
        }
      };
      database = await request(opening);
      database.onversionchange = () => { database.close(); database = null; releaseLock?.(); };
    } catch (error) { releaseLock?.(); releaseLock = null; throw error; }
  }
  async function read(store) {
    const tx = database.transaction(store);
    const done = complete(tx);
    const result = await request(tx.objectStore(store).getAll());
    await done;
    return result;
  }
  async function write(changes) {
    if (!changes.length) return;
    const tx = database.transaction([...new Set(changes.map(c => c.store))], 'readwrite');
    const done = complete(tx);
    try {
      for (const change of changes) {
        const store = tx.objectStore(change.store);
        for (const id of change.delete) store.delete(id);
        for (const row of change.put) store.put(row);
      }
    } catch (error) { tx.abort(); await done.catch(() => {}); throw error; }
    await done;
  }
  let municipalities;
  let lastLookup = 0;
  async function place({latitude, longitude}) {
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude) ||
        Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return '';
    const id = `${latitude.toFixed(5)},${longitude.toFixed(5)}`;
    const cached = await request(database.transaction('places').objectStore('places').get(id));
    if (cached) return cached.name;
    if (!navigator.onLine) throw new Error('Offline');
    // User-triggered, sequential, cached lookups; no automatic bulk requests.
    await new Promise(resolve => setTimeout(resolve, Math.max(0, 1100 - (Date.now() - lastLookup))));
    lastLookup = Date.now();
    const fetchText = async url => {
      const response = await fetch(url, {signal: AbortSignal.timeout(12000)});
      if (!response.ok) throw new Error(`Geocoder: ${response.status}`);
      return response.text();
    };
    if (!municipalities) {
      const source = await fetchText('https://maps.gsi.go.jp/js/muni.js');
      municipalities = new Map();
      for (const match of source.matchAll(/MUNI_ARRAY\["(\d+)"\]\s*=\s*'([^']+)'/g)) {
        const parts = match[2].split(',');
        municipalities.set(String(Number(match[1])), `${parts[1]} ${parts[3]}`);
      }
    }
    const data = JSON.parse(await fetchText(
      `https://mreversegeocoder.gsi.go.jp/reverse-geocoder/LonLatToAddress?lat=${latitude}&lon=${longitude}`));
    const result = data.results;
    if (!result?.muniCd || !result.lv01Nm) return '';
    const name = [municipalities.get(String(Number(result.muniCd))), result.lv01Nm].filter(Boolean).join(' ');
    await write([{store: 'places', delete: [], put: [{id, name}]}]);
    return name;
  }
  async function status({request: persist}) {
    if (persist && navigator.storage?.persist) await navigator.storage.persist();
    const permanent = await navigator.storage?.persisted?.() || false;
    const estimate = await navigator.storage?.estimate?.();
    const mb = bytes => (bytes / 1024 / 1024).toFixed(1);
    return `${permanent ? '永続保存：許可済み' : '永続保存：未許可（通常保存）'}。` +
      (estimate ? `使用量 約${mb(estimate.usage || 0)} MB / 上限目安 約${mb(estimate.quota || 0)} MB。` : '') +
      'ブラウザのサイトデータ削除では記録も消えます。';
  }
  window.birdlogStorage = async (command, encoded) => {
    const payload = JSON.parse(encoded);
    let result = null;
    switch (command) {
      case 'open': await open(); break;
      case 'read': result = await read(payload); break;
      case 'write': await write(payload); break;
      case 'status': result = await status(payload); break;
      case 'place': result = await place(payload); break;
      case 'close': database?.close(); database = null; releaseLock?.(); releaseLock = null; break;
      default: throw new Error(`Unknown command: ${command}`);
    }
    return JSON.stringify(result);
  };
})();
