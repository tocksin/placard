const {chromium}=require('playwright');
const views=require('./views.json');
(async()=>{
 const b=await chromium.launch({args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const p=await b.newPage({viewport:{width:1600,height:1000}});
 p.on('console',m=>{ if(m.type()==='error') console.log('ERR',m.text())});
 p.on('pageerror',e=>console.log('PAGEERR',e.message));
 for(const [name,v] of Object.entries(views)){
   if(process.argv[2] && !process.argv.slice(2).includes(name)) continue;
   await p.setViewportSize({width:v.w||1600,height:v.h||1000});
   await p.goto('http://localhost:8765/render_case.html?v='+encodeURIComponent(JSON.stringify(v)));
   await p.waitForFunction('window.done===true',null,{timeout:240000});
   await p.screenshot({path:'out/'+name+'.png'});
   console.log('ok',name);
 }
 await b.close();
})();
