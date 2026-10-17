// Hand-written candidate output, not compiler output: local row handles and
// proven edits over one owned plain array. The labels/operations are JFB's.
const adjectives = ['pretty','large','big','small','tall','short','long','handsome','plain','quaint','clean','elegant','easy','angry','crazy','helpful','mushy','odd','unsightly','adorable','important','inexpensive','cheap','expensive','fancy'];
const colors = ['red','yellow','blue','green','pink','brown','purple','brown','white','black','orange'];
const nouns = ['table','chair','house','bbq','desk','car','pony','cookie','sandwich','burger','pizza','mouse','keyboard'];
const pick = a => a[Math.round(Math.random()*1000)%a.length];
let generation=0,next=1,rows=[],selected=null,dead=false,running=false;
const queue=[];
function enter(f){
 if(dead)return;
 if(running){queue.push(f);return}
 running=true;let ok=false;
 try{f();while(queue.length)queue.shift()();ok=true}
 finally{running=false;if(!ok){dead=true;queue.length=0}}
}
const body=document.querySelector('tbody');
const template=document.createElement('template');
template.innerHTML='<tr><td class="col-md-1"></td><td class="col-md-4"><a></a></td><td class="col-md-1"><a><span class="glyphicon glyphicon-remove" aria-hidden="true"></span></a></td><td class="col-md-6"></td></tr>';
function select(row){if(!row.live||row.generation!==generation)return;if(selected)selected.node.className='';selected=row;row.node.className='danger'}
function remove(row){const i=rows.indexOf(row);if(i<0)return;rows.splice(i,1);row.live=false;row.node.remove();if(selected===row)selected=null}
function build(count){
 const fragment=document.createDocumentFragment();
 for(let i=0;i<count;i++){
  const id=next++,label=pick(adjectives)+' '+pick(colors)+' '+pick(nouns),node=template.content.firstChild.cloneNode(true),link=node.children[1].firstChild;
  const row={id,label,node,link,live:true,generation};node.firstChild.textContent=id;link.textContent=label;
  link.onclick=()=>enter(()=>select(row));node.children[2].firstChild.onclick=()=>enter(()=>remove(row));
  rows.push(row);fragment.append(node);
 }
 body.append(fragment);
}
function clear(){generation++;body.textContent='';rows=[];selected=null}
const actions={run(){clear();build(1000)},runlots(){clear();build(10000)},add(){build(1000)},update(){for(let i=0;i<rows.length;i+=10){const row=rows[i];row.label+=' !!!';row.link.firstChild.data=row.label}},clear,swaprows(){if(rows.length>998){const a=rows[1],b=rows[998],after=b.node.nextSibling;body.insertBefore(b.node,a.node);body.insertBefore(a.node,after);rows[1]=b;rows[998]=a}}};
for(const [id,action] of Object.entries(actions))document.getElementById(id).onclick=()=>enter(action);
