const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch({args:['--enable-unsafe-swiftshader','--use-gl=angle','--use-angle=swiftshader']});
const p=await b.newPage();p.on('console',m=>{const t=m.text();console.log('C:',t.slice(0,300));if(t.includes('LUAUTEST done')||t.includes('LUAUTEST FAIL'))p.evaluate(()=>{window.__done=true}).catch(()=>{})});p.on('pageerror',e=>console.log('ERR:',String(e).slice(0,300)));
await p.goto('http://localhost:8072/index.html');await p.waitForFunction(()=>window.__done,null,{timeout:400000}).catch(()=>{});await b.close();})();
