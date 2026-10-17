import {createSignal,Show} from 'solid-js';
export default function Shared(){const [count,setCount]=createSignal(0),[name,setName]=createSignal('');return <div><button onClick={()=>setCount(n=>n+1)}>Increment</button><output>{count()*2}</output><input value={name()} onInput={e=>setName(e.target.value)}/><Show when={name().length<3}><p>Too short</p></Show></div>}
