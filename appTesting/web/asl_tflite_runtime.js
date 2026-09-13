// TensorFlow Lite runs locally. This small loader keeps the pinned TFJS runtime
// lazy so the camera UI can start while model assets are being prepared.
const VENDOR_ROOT = new URL('./vendor/tflite/', import.meta.url);
let runtimePromise;

function loadScript(file) {
  return new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = new URL(file, VENDOR_ROOT).toString();
    script.onload = resolve;
    script.onerror = () => {
      script.remove();
      reject(new Error(`ASL runtime ${file} is missing. Run python3 tool/setup_asl_model.py.`));
    };
    document.head.appendChild(script);
  });
}

async function loadRuntime() {
  if (!runtimePromise) {
    runtimePromise = (async () => {
      if (!globalThis.tf) await loadScript('tf-core.min.js');
      if (!globalThis.tf.findBackend('cpu')) await loadScript('tf-backend-cpu.min.js');
      await globalThis.tf.setBackend('cpu');
      await globalThis.tf.ready();
      if (!globalThis.tflite) await loadScript('tf-tflite.min.js');
      globalThis.tflite.setWasmPath(VENDOR_ROOT.toString());
      return {tf: globalThis.tf, tflite: globalThis.tflite};
    })().catch((error) => {
      runtimePromise = undefined;
      throw error;
    });
  }
  return runtimePromise;
}

export async function createAslModelHandle(modelUrl, manifest) {
  const {tf, tflite} = await loadRuntime();
  const model = await tflite.loadTFLiteModel(modelUrl, {numThreads: 1});
  if (model.inputs.length !== 1 || model.outputs.length !== 1 ||
      model.inputs[0].name !== manifest.input_name ||
      model.outputs[0].name !== manifest.output_name ||
      model.inputs[0].dtype !== 'float32' ||
      JSON.stringify(model.inputs[0].shape) !== JSON.stringify(manifest.input_shape) ||
      JSON.stringify(model.outputs[0].shape) !== JSON.stringify(manifest.output_shape)) {
    model.dispose();
    throw new Error('ASL model tensors do not match the installed manifest.');
  }
  return {
    provider: 'tflite_wasm',
    predict(values) {
      const input = tf.tensor(values, manifest.input_shape, 'float32');
      let output;
      try {
        output = model.predict(input);
        // Copy out of WASM memory before disposing TFJS tensors.
        return Float32Array.from(output.dataSync());
      } finally {
        input.dispose();
        if (output) tf.dispose(output);
      }
    },
    dispose: () => model.dispose(),
  };
}
