(() => {
  const bar = document.getElementById('pwa-status');
  const message = document.getElementById('pwa-message');
  const show = text => { message.textContent = text; bar.hidden = false; };
  document.getElementById('dismiss-status').onclick = () => { bar.hidden = true; };
  window.addEventListener('offline', () => show('オフライン：記録・編集・集計できます。地図はキャッシュにある範囲のみ表示されます。'));
  window.addEventListener('online', () => show('オンラインに戻りました。'));
  if (!('serviceWorker' in navigator)) {
    show('このブラウザではオフライン起動を利用できません。');
    return;
  }
  navigator.serviceWorker.register('service-worker.js', {scope: './', updateViaCache: 'none'})
    .then(async registration => {
      const ready = () => show(navigator.onLine
        ? 'オフライン利用の準備ができました。ホーム画面にも追加できます。'
        : 'オフライン：記録・編集・集計できます。地図はキャッシュにある範囲のみ表示されます。');
      if (registration.active) ready();
      const watch = worker => {
        if (!worker) return;
        worker.addEventListener('statechange', () => {
          if (worker.state === 'activated') ready();
          if (worker.state === 'installed' && registration.active) {
            show('新しい版を準備しました。記録を終え、アプリのタブをすべて閉じてから開くと更新されます。');
          }
          if (worker.state === 'redundant') show('オフライン準備が完了していません。通信状態を確認し、再読み込みしてください。');
        });
      };
      watch(registration.installing);
      registration.addEventListener('updatefound', () => watch(registration.installing));
    }).catch(() => show('オフライン準備が完了していません。初回は通信できる状態で開いてください。'));
})();
