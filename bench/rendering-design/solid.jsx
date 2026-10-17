import {createSignal,createProjection,For} from 'solid-js';
import {render} from '@solidjs/web';
const Frame=props=>{
 const c=props.c,id='s'+c.index,label=c.shape+' '+c.seed+'/'+c.index+' '+['Review','Work','People','Activity'][c.variant%4];
 const Nest=p=>p.level<0?p.children:<div class={'level-'+p.level}><Nest level={p.level-1}>{p.children}</Nest></div>;
 return <section id={id} data-shape={c.shape}><h2>{label}</h2><Nest level={c.depth-2}>{props.children}</Nest></section>;
};
const List=props=>{
 const c=props.c,id='s'+c.index,label=c.shape+' '+c.seed+'/'+c.index+' '+['Review','Work','People','Activity'][c.variant%4];let next=c.population+1;
 const row=(id,text,points)=>{const [title,setTitle]=createSignal(text),[score,setScore]=createSignal(points),[done,setDone]=createSignal(false);return {id,title,setTitle,score,setScore,done,setDone}};
 const [rows,setRows]=createSignal(Array.from({length:c.population},(_,i)=>row(i+1,'Item '+(i+1),(i+1)*c.step%17)));
 const [selected,setSelected]=createSignal(0);
 const isSelected=createProjection(s=>{const id=selected();if(s._prev!=null)delete s[s._prev];s[id]=true;s._prev=id},{});
 const add=()=>{const item=row(next,label+' '+next,c.step);next++;setRows(xs=>[...xs,item])};
 const edit=item=>{item.setTitle(s=>s+'!');item.setScore(n=>n+c.step);item.setDone(x=>!x)};
 const remove=item=>{setRows(xs=>xs.filter(r=>r.id!==item.id));if(c.variant%2===0)setSelected(0)};
 return <Frame c={c}><button id={id+'-add'} onClick={add}>Add</button><button id={id+'-reverse'} onClick={()=>setRows(xs=>xs.toReversed())}>Reverse</button><p>{rows().length} records</p><ul><For each={rows()}>{item=><li data-row={String(item.id)} class={isSelected[item.id]?'selected':''}><button onClick={()=>setSelected(item.id)}>{item.title()}</button><output>{item.score()}</output><button onClick={()=>edit(item)}>Edit</button><button onClick={()=>remove(item)}>Remove</button></li>}</For></ul></Frame>;
};
const Form=props=>{
 const c=props.c,id='s'+c.index;
 const [name,setName]=createSignal(''),[email,setEmail]=createSignal(''),[submitted,setSubmitted]=createSignal(false),[attempts,setAttempts]=createSignal(0);
 const inputName=e=>{if(!e.target.value.includes('#')){setName(e.target.value);if(c.variant%2===0)setSubmitted(false)}else e.target.value=name()};
 const reset=()=>{setName('');setEmail('');setSubmitted(false)};
 return <Frame c={c}><label>Name<input id={id+'-name'} value={name()} onInput={inputName}/></label><label>Email<input id={id+'-email'} value={email()} onInput={e=>{setEmail(e.target.value);setSubmitted(false)}}/></label><p id={id+'-validation'}>{Array.from(name()).length<2+c.variant%4?'Name too short':email().includes('@')?'Ready':'Email needs @'}</p><button id={id+'-submit'} onClick={()=>{setSubmitted(true);setAttempts(n=>n+1)}}>Submit</button><button id={id+'-reset'} onClick={reset}>Reset</button><p hidden={!submitted()}>Saved {name()} / {attempts()}</p></Frame>;
};
// CASE_CONFIG is replaced by solid.mjs; only these two real ports are claimed.
const cases=CASE_CONFIG;
render(()=>cases.map(c=>c.shape==='list'?<List c={c}/>:<Form c={c}/>),document.body);
