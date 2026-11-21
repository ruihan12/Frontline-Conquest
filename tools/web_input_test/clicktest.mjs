// node clicktest.mjs <url>   env: PRE=stepsfile (menu flow, then real spawn click), UDIR, SHOT, BUILD=1
import { spawn } from 'node:child_process'; import fs from 'node:fs';
const url = process.argv[2]; const port = 9400 + Math.floor(Math.random()*500);
const chrome = spawn('google-chrome', ['--headless=new','--no-sandbox','--enable-unsafe-swiftshader','--use-angle=swiftshader','--ignore-gpu-blocklist',
  `--remote-debugging-port=${port}`,'--window-size='+(process.env.WS||'1600,900'),'--user-data-dir='+(process.env.UDIR||('/tmp/drv_'+port)),'about:blank'], {stdio:'ignore'});
const sleep = ms => new Promise(r=>setTimeout(r,ms));
let ws; for (let i=0;i<50;i++){ try{ const r=await fetch(`http://127.0.0.1:${port}/json`); const j=await r.json(); const p=j.find(x=>x.type==='page'); if(p){ ws=new WebSocket(p.webSocketDebuggerUrl); break;} }catch(e){} await sleep(200); }
await new Promise(r=>ws.onopen=r);
let id=0; const pend={}; const t0=Date.now(); const ts=()=>((Date.now()-t0)/1000).toFixed(1);
ws.onmessage = ev => { const m=JSON.parse(ev.data); if(m.id&&pend[m.id]){pend[m.id](m);delete pend[m.id];}
  else if(m.method==='Runtime.consoleAPICalled'){ const s=m.params.args.map(a=>a.value??a.description).join(' '); if(!s.startsWith('FCTEST')&&!/^(Godot Engine|OpenGL API)/.test(s)) console.log(ts(),'[console]', s.slice(0,300)); }
  else if(m.method==='Runtime.exceptionThrown'){ console.log(ts(),'[exception]', JSON.stringify(m.params.exceptionDetails).slice(0,300)); } };
const send=(method,params={})=>new Promise(r=>{const i=++id;pend[i]=r;ws.send(JSON.stringify({id:i,method,params}));});
const fc=async()=>{ const r=await send('Runtime.evaluate',{expression:'JSON.stringify(window._fc||null)',returnByValue:true}); return JSON.parse(r.result.result.value); };
const click=async(x,y,b='left')=>{ await send('Input.dispatchMouseEvent',{type:'mouseMoved',x,y}); await sleep(100);
  await send('Input.dispatchMouseEvent',{type:'mousePressed',x,y,button:b,clickCount:1}); await sleep(80);
  await send('Input.dispatchMouseEvent',{type:'mouseReleased',x,y,button:b,clickCount:1}); };
const keyp=async(k,c,code=k)=>{ for(const type of ['keyDown','keyUp']) await send('Input.dispatchKeyEvent',{type,key:k,code,windowsVirtualKeyCode:c}); };
const shot=async f=>{ const r=await send('Page.captureScreenshot',{format:'png'}); fs.writeFileSync(f, Buffer.from(r.result.data,'base64')); };
await send('Runtime.enable'); await send('Page.navigate',{url});
if(process.env.PRE){ for(const line of fs.readFileSync(process.env.PRE,'utf8').split('\n')){ const p=line.trim().split(' '); if(!p[0]||p[0][0]=='#') continue; console.log(ts(),'PRE',line.trim());
  if(p[0]==='wait') await sleep(+p[1]*1000); else if(p[0]==='click') await click(+p[1],+p[2]); else if(p[0]==='key') await keyp(p[1],+p[2]); else if(p[0]==='shot') await shot(p[1]); } }
let s=null; let spawned=false;
for(let i=0;i<150;i++){ await sleep(1000); s=await fc();
  if(s&&s.state==='pick'&&s.start_tile<0&&s.free_px&&!spawned&&process.env.PRE){ await sleep(1500); s=await fc(); console.log(ts(),'SPAWN CLICK', s.free_px, s.free_tile, 'hovered', s.hovered); await click(Math.round(s.free_px[0]),Math.round(s.free_px[1])); spawned=true; await sleep(1500); const q=await fc(); console.log(ts(),'after spawn click: land',q.land,'start',q.start_tile,'state',q.state); if(q.start_tile<0){ spawned=false; await shot('/tmp/fc_spawnfail.png'); } }
  if(s&&s.state==='play'&&s.neutral_px&&(process.env.TARGET!=='far'||s.far_px)) break; }
console.log(ts(),'PLAY', JSON.stringify(s));
await sleep(+(process.env.SETTLE||3)*1000); s=await fc();
const land0=s.land, tick0=s.tick;
const tp = (process.env.TARGET==='far' && s.far_px) ? s.far_px : s.neutral_px; if(process.env.TARGET==='far' && !s.far_px) console.log('NOTE: no far tile, using adjacent');
const b0=s.boats;
console.log(ts(),'CLICK', process.env.TARGET||'adj', 'at', tp, process.env.TARGET==='far'?s.far_tile:s.neutral_tile, 'hovered', s.hovered);
await click(Math.round(tp[0]), Math.round(tp[1]));
for(let k=0;k<8;k++){ await sleep(1000); const q=await fc(); console.log(ts(),`t+${k+1}s state=${q.state} tick=${q.tick} land=${q.land} attacks=${q.attacks} troops=${Math.round(q.troops)} gold=${q.gold} hovered=${q.hovered} fps=${q.fps}`); s=q; }
await shot(process.env.SHOT||'/tmp/fc_ct.png');
console.log('RESULT', (s.land>land0 || s.attacks>0) && s.boats==b0 ? 'ATTACK_OK':'ATTACK_FAIL', 'land', land0,'->',s.land, 'boats', b0,'->',s.boats, 'ticks', tick0,'->',s.tick);
if(process.env.BUILD){
  s=await fc(); console.log('gold after console', s.gold);
  const st0=s.structs; await keyp('1',49,'Digit1'); await sleep(500); await click(Math.round(s.build_px[0]),Math.round(s.build_px[1])); await sleep(3000); const q=await fc(); console.log('BUILD', q.structs>st0?'BUILD_OK':'BUILD_FAIL','structs',st0,'->',q.structs,'gold',s.gold,'->',q.gold); await shot('/tmp/fc_build.png'); }
ws.close(); chrome.kill('SIGKILL'); process.exit(0);
