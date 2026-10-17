// Independent handwritten-style controls. No BIR, dependency graph or prototype
// DOM compiler. One reusable component implementation per catalogue structure.
function vanilla(c){
 const {shape,index,seed,variant,depth,step,population}=c;
 const id='s'+index,label=shape+' '+seed+'/'+index+' '+['Review','Work','People','Activity'][variant%4];
 const root=document.createElement('section');root.id=id;root.dataset.shape=shape;
 const title=document.createElement('h2');title.textContent=label;root.append(title);let host=root;
 for(let i=depth-2;i>=0;i--){const div=document.createElement('div');div.className='level-'+i;host.append(div);host=div;}
 document.body.append(root);
 const html=s=>{host.insertAdjacentHTML('beforeend',s);};
 const get=selector=>root.querySelector(selector);
 const on=(selector,event,fn)=>{const n=get(selector);n.addEventListener(event,()=>guarded(()=>{fn(n);}))};
 const button=(name,text=name,arg='')=>`<button id="${id}-${name.toLowerCase()}${arg!==''?'-'+arg:''}">${text}</button>`;
 const setText=(n,v)=>{v=String(v);if(n.textContent!==v)n.textContent=v};
 const inputValue=(n,v)=>{if(n.value!==v)n.value=v};
 if(shape==='cluster'){
  let count=0,enabled=true,history=0;
  html(button('Increment')+button('Toggle')+button('Reset')+`<output id="${id}-count"></output><span></span>`);
  const out=get('output'),span=get('span');const patch=()=>{setText(out,count);span.hidden=!enabled;setText(span,history)};
  on('[id$="-increment"]','click',()=>{count+=step;if(variant%2===0)history++;enqueue(patch)});
  on('[id$="-toggle"]','click',()=>{enabled=!enabled;history++;enqueue(patch)});
  on('[id$="-reset"]','click',()=>{count=history=0;enqueue(patch)});patch();
 }else if(shape==='form'){
  let name='',email='',submitted=false,attempts=0;
  html(`<label>Name<input id="${id}-name"></label><label>Email<input id="${id}-email"></label><p id="${id}-validation"></p>`+button('Submit')+button('Reset')+'<p hidden></p>');
  const nameNode=get('[id$="-name"]'),emailNode=get('[id$="-email"]'),validation=get('[id$="-validation"]'),saved=root.querySelectorAll('p')[1];
  const patch=()=>{inputValue(nameNode,name);inputValue(emailNode,email);setText(validation,core.String_length(name)<2+variant%4?'Name too short':email.includes('@')?'Ready':'Email needs @');saved.hidden=!submitted;saved.replaceChildren(document.createTextNode('Saved '),document.createTextNode(name),document.createTextNode(' / '),document.createTextNode(String(attempts)))};
  on('[id$="-name"]','input',n=>{if(!n.value.includes('#')){name=n.value;if(variant%2===0)submitted=false}enqueue(patch)});
  on('[id$="-email"]','input',n=>{email=n.value;submitted=false;enqueue(patch)});
  on('[id$="-submit"]','click',()=>{submitted=true;attempts++;enqueue(patch)});
  on('[id$="-reset"]','click',()=>{name=email='';submitted=false;enqueue(patch)});patch();
 }else if(shape==='tabs'){
  let tab=0,unread=step,draft='',shown=-1,live=0;
  html(button('Choose','Overview','0')+button('Choose','Messages','1')+`<div id="${id}-panel"></div>`);const panel=get('[id$="-panel"]');
  const patch=()=>{if(shown!==tab){shown=tab;const token=++live;
   panel.innerHTML=tab===0?'<article><h3>Overview</h3><p></p>'+button('Read')+'</article>':`<aside><h3>Compose</h3><input id="${id}-draft"><p></p></aside>`;
   if(tab===0)panel.querySelector('button').onclick=()=>guarded(()=>{if(token===live){unread=0;enqueue(patch)}});
   else panel.querySelector('input').oninput=e=>guarded(()=>{if(token===live){draft=e.target.value;enqueue(patch)}});
  }if(tab===0){panel.querySelector('p').replaceChildren(document.createTextNode(String(unread)),document.createTextNode(' unread'))}else{inputValue(panel.querySelector('input'),draft);setText(panel.querySelector('p'),draft)}};
  on('[id$="-choose-0"]','click',()=>{tab=0;if(variant%2===0)unread=0;enqueue(patch)});on('[id$="-choose-1"]','click',()=>{tab=1;if(variant%2===0)unread=0;enqueue(patch)});patch();
 }else if(shape==='nested'){
  let left=0,right=step,expanded=true;
  html(button('Collapse')+`<p id="${id}-total"></p><div></div>`);const box=host.lastChild,total=get('p');
  const card=(level,isLeft)=>{let parent=box;while(level--){const div=document.createElement('div');div.className='nested';parent.append(div);parent=div}const n=document.createElement('article');n.innerHTML='<h3>Leaf</h3><output></output><button>Child action</button>';parent.append(n);n.querySelector('button').onclick=()=>guarded(()=>{if(isLeft)left+=step;else{right+=step;if(variant%2===0)left++}enqueue(patch)});return n.querySelector('output')};
  const l=card(depth,true),r=card(depth+1,false);const patch=()=>{setText(total,left+right);box.hidden=!expanded;setText(l,left);setText(r,right)};
  on('[id$="-collapse"]','click',()=>{expanded=!expanded;enqueue(patch)});patch();
 }else if(shape==='thread'){
  let collapsed=false;html(button('Collapse')+'<div></div>');const box=host.lastChild;
  const tree=[0,'Root '+variant,0,[[1,'First',0,[[2,'Nested',0,[]]]],[3,'Second',0,[]]]];
  const comment=(data,parent)=>{const n=document.createElement('article');n.dataset.comment=data[0];n.innerHTML='<strong></strong><output></output><button>Vote</button><input><div></div>';parent.append(n);const title=n.querySelector('strong'),score=n.querySelector('output'),input=n.querySelector('input');const patch=()=>{setText(title,data[1]);setText(score,data[2]);inputValue(input,data[1])};n.querySelector('button').onclick=()=>guarded(()=>{data[2]+=step;enqueue(patch)});input.oninput=()=>guarded(()=>{data[1]=input.value;enqueue(patch)});for(const child of data[3])comment(child,n.lastChild);patch()};
  comment(tree,box);on('[id$="-collapse"]','click',()=>{collapsed=!collapsed;enqueue(()=>{box.hidden=collapsed})});
 }else if(shape==='modal'){
  let open=false,draft='',saved='',visits=0,dialog=null,live=0;
  html(button('Open')+`<output id="${id}-saved"></output><span></span>`);const output=get('output'),counter=get('span');
  const patch=()=>{setText(output,saved);setText(counter,visits);if(open&&!dialog){const token=++live;dialog=document.createElement('div');dialog.setAttribute('role','dialog');dialog.setAttribute('aria-label','Edit');dialog.innerHTML=`<h3>Edit ${variant}</h3><input id="${id}-draft">`+button('Confirm')+button('Close');host.append(dialog);dialog.querySelector('input').oninput=e=>guarded(()=>{if(token===live){draft=e.target.value;enqueue(patch)}});dialog.querySelector('[id$="-confirm"]').onclick=()=>guarded(()=>{if(token===live){saved=draft;open=false;enqueue(patch)}});dialog.querySelector('[id$="-close"]').onclick=()=>guarded(()=>{if(token===live){open=false;enqueue(patch)}})}else if(!open&&dialog){dialog.remove();dialog=null;live++}if(dialog)inputValue(dialog.querySelector('input'),draft)};
  on('[id$="-open"]','click',()=>{open=true;draft=saved;visits++;enqueue(patch)});patch();
 }else{
  const rows=Array.from({length:population},(_,i)=>({id:i+1,title:'Item '+(i+1),score:(i+1)*step%17,done:false}));let next=population+1,selected=0,descending=false,query='',onlyDone=false,rate=step,oldNodes=[],cache=new Map();
  html(button('Add')+button('Reverse')+(shape==='filter'?`<input id="${id}-query">`+button('OnlyDone'):'')+(shape==='summary'?button('Rate')+`<dl><dt>Total</dt><dd id="${id}-total"></dd><dt>Completed</dt><dd></dd></dl>`:'')+'<p></p>'+(shape==='table'?'<table><thead><tr><th>'+button('Sort')+'</th><th>Score</th><th>Actions</th></tr></thead><tbody></tbody></table>':'<ul></ul>'));
  const list=get(shape==='table'?'tbody':'ul'),count=get('p');
  const patchRow=(entry,row)=>{entry.node.className=selected===row.id?'selected':'';setText(entry.label,row.title);setText(entry.score,row.score)};
  const rowNode=row=>{const n=document.createElement(shape==='table'?'tr':'li');n.dataset.row=row.id;n.innerHTML=shape==='table'?'<td><button></button></td><td></td><td><button>Edit</button><button>Remove</button></td>':'<button></button><output></output><button>Edit</button><button>Remove</button>';const bs=n.querySelectorAll('button'),entry={node:n,label:bs[0],score:n.querySelector(shape==='table'?'td:nth-child(2)':'output'),live:true};bs[0].onclick=()=>guarded(()=>{if(!entry.live)return;const previous=selected;selected=row.id;enqueue(()=>{const old=cache.get(previous);if(old)old.node.className='';n.className='selected'})});bs[1].onclick=()=>guarded(()=>{if(!entry.live)return;row.title+='!';row.score+=step;row.done=!row.done;enqueue(shape==='list'?()=>{patchRow(entry,row)}:patch)});bs[2].onclick=()=>guarded(()=>{if(!entry.live)return;const i=rows.indexOf(row);if(i>=0)rows.splice(i,1);if(variant%2===0)selected=0;enqueue(patch)});patchRow(entry,row);return entry};
  const patch=()=>{
   count.replaceChildren(document.createTextNode(String(rows.length)),document.createTextNode(' records'));
   if(shape==='summary'){setText(get('[id$="-total"]'),rows.reduce((s,r)=>s+r.score,0)*rate);setText(root.querySelectorAll('dd')[1],rows.filter(r=>r.done).length)}
   if(shape==='filter')inputValue(get('input'),query);
   let shown=shape==='filter'?rows.filter(r=>r.title.includes(query)&&(!onlyDone||r.done)):shape==='table'?rows.toSorted((a,b)=>a.score-b.score):rows;if(shape==='table'&&descending)shown=shown.toReversed();
   const keep=new Set(),nodes=[];for(const row of shown){keep.add(row.id);let entry=cache.get(row.id);if(!entry){entry=rowNode(row);cache.set(row.id,entry);if(!oldNodes.length)list.append(entry.node)}else patchRow(entry,row);nodes.push(entry.node)}
   if(oldNodes.length&&(oldNodes.length!==nodes.length||oldNodes.some((n,i)=>n!==nodes[i])))reconcileArrays(list,oldNodes,nodes,null);
   for(const [key,entry] of cache)if(!keep.has(key)){entry.live=false;entry.node.remove();cache.delete(key)}oldNodes=nodes;
  };
  on('[id$="-add"]','click',()=>{rows.push({id:next,title:label+' '+next,score:step,done:false});next++;enqueue(patch)});
  on('[id$="-reverse"]','click',()=>{rows.reverse();enqueue(patch)});
  if(shape==='table')on('[id$="-sort"]','click',()=>{descending=!descending;enqueue(patch)});
  if(shape==='filter'){on('input','input',n=>{query=n.value;enqueue(patch)});on('[id$="-onlydone"]','click',()=>{onlyDone=!onlyDone;enqueue(patch)})}
  if(shape==='summary')on('[id$="-rate"]','click',()=>{rate++;enqueue(patch)});patch();
 }
}
