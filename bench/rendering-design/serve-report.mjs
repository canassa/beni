// Serve only the generated standalone report, on loopback.
import http from 'node:http';import fs from 'node:fs';
const file=import.meta.dirname+'/report.html',port=Number(process.env.PORT||8765);
http.createServer((req,res)=>{if(!['/','/report.html'].includes(new URL(req.url,'http://localhost').pathname)){res.writeHead(404);res.end('Not found');return;}res.setHeader('Content-Type','text/html; charset=utf-8');res.setHeader('Cache-Control','no-store');res.end(fs.readFileSync(file));}).listen(port,'127.0.0.1',()=>console.log(`http://127.0.0.1:${port}/report.html`));
