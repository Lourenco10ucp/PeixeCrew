/* PeixeCrew: guarda a app no aparelho para funcionar sem rede.
   Mude VERSION a cada publicação: os aparelhos detetam a versão nova e mostram «Atualizar». */
const VERSION='2026-11-17-1';
const CACHE='peixecrew-'+VERSION;
const ASSETS=['./','./index.html','./manifest.webmanifest','./vendor/supabase.js','./icons/icon-180.png','./icons/icon-192.png','./icons/icon-512.png'];
// cache:'reload' obriga a ir ao servidor: o GitHub Pages deixa os navegadores guardar ficheiros 10 min, e sem isto a versão nova podia ficar com o index antigo
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS.map(u=>new Request(u,{cache:'reload'})))))});
self.addEventListener('message',e=>{if(e.data==='skipWaiting')self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k.startsWith('peixecrew-')&&k!==CACHE&&k!=='peixecrew-fontes').map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const req=e.request;if(req.method!=='GET')return;
  const url=new URL(req.url);
  // A app: primeiro o que está guardado (funciona sem rede); as previsões e avisos vêm sempre da rede, pela página.
  if(url.origin===location.origin){
    if(req.mode==='navigate'){e.respondWith(caches.match('./index.html').then(r=>r||fetch(req)));return}
    e.respondWith(caches.match(req,{ignoreSearch:true}).then(r=>r||fetch(req)));return;
  }
  // Tipos de letra: guardados na primeira visita, para o aspeto ficar igual sem rede
  if(url.host==='fonts.googleapis.com'||url.host==='fonts.gstatic.com'){
    e.respondWith(caches.open('peixecrew-fontes').then(c=>c.match(req).then(r=>r||fetch(req).then(res=>{if(res.ok||res.type==='opaque')c.put(req,res.clone());return res}))));
  }
});
