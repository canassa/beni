let initialized = false;
export const installFor = development => {
  const Native = globalThis.Worker;
  globalThis.Worker = function(url, options) {
    const other = url.replace(/\/(?:out|release)\/_workers\//, development ? "/release/_workers/" : "/out/_workers/");
    if (other === url) throw new Error("mixed-build fixture did not select the other build");
    const worker = new Native(other, options);
    worker.addEventListener("message", event => {
      if (event.data.initialized === true) initialized = true;
    });
    return worker;
  };
};
export const started = () => globalThis.postMessage({initialized: true});
export const untouched = () => !initialized;
