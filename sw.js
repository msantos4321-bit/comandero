// Comandero: guarda la app en el aparato para que abra rápido y funcione sin internet.
// v54 (20 nov 2026): ya no borra las cajas de otras apps (la de «demos sin internet» de
// Mostrador Ventas), los datos .json van primero por la red y la app de pedidos (pedir/)
// también abre sin internet si ya está guardada.
const C='comandero-v54';
const ARCH=['./','index.html','manifest.json','icono.svg','icono-192.png','icono-512.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(ARCH.map(u=>new Request(u,{cache:'reload'})))).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k.startsWith('comandero-')&&k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
const copia=r=>caches.match(r).then(m=>m||caches.match(r,{ignoreSearch:true}));
self.addEventListener('fetch',e=>{
  const r=e.request;if(r.method!=='GET')return;
  const u=new URL(r.url);
  if(r.mode==='navigate'){const rel=r.url.slice(self.registration.scope.length).split(/[?#]/)[0];
    if(rel&&rel!=='index.html'){e.respondWith(fetch(r).catch(()=>copia(r).then(m=>m||caches.match(u.pathname.replace(/\/?$/,'/')+'index.html')).then(m=>m||Response.error())));return}
    e.respondWith(fetch(new Request(r.url,{cache:'no-cache',credentials:'same-origin'})).then(res=>{const cp=res.clone();caches.open(C).then(c=>c.put('index.html',cp));return res}).catch(()=>caches.match('index.html')));return}
  // Datos (menús, configuración): siempre lo más nuevo; sin internet, la copia guardada
  if(u.origin===location.origin&&/\.json$/i.test(u.pathname)){e.respondWith(fetch(r).catch(()=>copia(r).then(m=>m||Response.error())));return}
  e.respondWith(caches.match(r).then(m=>m||fetch(r).then(res=>{try{if(res.ok&&/\/p\/.+\.(webp|jpg|jpeg|png)$/i.test(u.pathname)){const cp=res.clone();caches.open(C).then(c=>c.put(r,cp))}}catch(_){}return res}).catch(()=>caches.match(r,{ignoreSearch:true}).then(m=>m||Response.error()))));
});
