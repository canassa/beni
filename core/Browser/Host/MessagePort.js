export const postUnit = (port) => { port.postMessage(null); return null; };
export const onMessage = (port, work) => { port.onmessage = () => work(null); return null; };
