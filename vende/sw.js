const C='ventas-v22';
self.addEventListener('install',e=>{self.skipWaiting();e.waitUntil(caches.open(C).then(c=>c.addAll(['./','demos.json','manifest.json','qr.js'].map(u=>new Request(u,{cache:'reload'})))).catch(()=>{}))});
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==location.origin||!u.pathname.includes('/vende/'))return;
  e.respondWith(fetch(e.request.mode==='navigate'?new Request(e.request.url,{cache:'no-cache',credentials:'same-origin'}):new Request(e.request,{cache:'no-cache'})).then(r=>{const cp=r.clone();caches.open(C).then(c=>c.put(e.request,cp));return r}).catch(()=>caches.match(e.request,{ignoreSearch:true})))});
