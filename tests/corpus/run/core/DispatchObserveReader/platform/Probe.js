// Test boundary: catch only to prove exact unknown-error propagation and fatal stop.
export const exercise = (observe,send,onDefect,busy,stopped) => {
 const events=[];
 const same=new Error('unknown-reader');
 let hooks=0;
 onDefect(()=>{hooks++;events.push('hook:'+busy(null)+':'+stopped(null))});
 observe(x=>send(y=>events.push(y),x),1,x=>{events.push('read:'+x);return x});
 // An outer guard holds the queue while observation projects immediately.
 send(()=>{
   observe(x=>send(y=>events.push(y),x),2,x=>{events.push('read:'+x);return x});
   send(x=>events.push(x),9);
   observe(x=>send(y=>events.push(y),x),3,x=>{events.push('read:'+x);return x});
   events.push('outer');
 },0);
 events.push('busy:'+busy(null));
 let propagated=false;
 try {
   observe(x=>{
     send(y=>{events.push(y);},x);
   },4,x=>{throw same;});
 } catch(error) { propagated=error===same; }
 observe(()=>events.push('BAD sender'),5,()=>{events.push('BAD reader');return 5});
 send(()=>events.push('BAD queued'),6);
 return events.join(',')+'|propagated:'+propagated+'|hooks:'+hooks+'|busy:'+busy(null)+'|stopped:'+stopped(null);
};
