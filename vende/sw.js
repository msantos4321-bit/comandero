// Mostrador Ventas. v23 (20 nov 2026): ya no borra las cajas de otras apps y, sin internet,
// también sirve los videos, portadas y guías que se descargaron con «Descargar demos para usar sin internet».
const C='ventas-v25';
self.addEventListener('install',e=>{self.skipWaiting();e.waitUntil(caches.open(C).then(c=>c.addAll(['./','demos.json','manifest.json','qr.js','sin-internet.json'].map(u=>new Request(u,{cache:'reload'})))).catch(()=>{}))});
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k.startsWith('ventas-')&&k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
// Partes de un video (el reproductor las pide por pedazos)
function pedazo(req,r){const rango=req.headers.get('range');if(!rango||!r||r.status!==200)return r;
  return r.arrayBuffer().then(b=>{const m=/bytes=(\d*)-(\d*)/.exec(rango)||[],ini=m[1]?+m[1]:0,fin=m[2]?Math.min(+m[2],b.byteLength-1):b.byteLength-1;
    return new Response(b.slice(ini,fin+1),{status:206,statusText:'Partial Content',headers:{'Content-Type':r.headers.get('Content-Type')||'video/mp4','Content-Range':`bytes ${ini}-${fin}/${b.byteLength}`,'Content-Length':String(fin-ini+1),'Accept-Ranges':'bytes'}})})}
const copia=r=>caches.match(r).then(m=>m||caches.match(r,{ignoreSearch:true}));
self.addEventListener('fetch',e=>{const r=e.request,u=new URL(r.url);if(r.method!=='GET')return;
  if(u.hostname==='fonts.googleapis.com'||u.hostname==='fonts.gstatic.com'){e.respondWith(copia(r).then(m=>m||fetch(r)));return}
  if(u.origin!==location.origin)return;
  if(!u.pathname.includes('/vende/')){ // videos, portadas, guías y logos de las demos: red primero, copia sin internet
    e.respondWith(fetch(r).catch(()=>copia(r).then(m=>m?pedazo(r,m):Response.error())));return}
  e.respondWith(fetch(r.mode==='navigate'?new Request(r.url,{cache:'no-cache',credentials:'same-origin'}):new Request(r,{cache:'no-cache'})).then(res=>{const cp=res.clone();caches.open(C).then(c=>c.put(r,cp));return res}).catch(()=>caches.match(r,{ignoreSearch:true})))});
