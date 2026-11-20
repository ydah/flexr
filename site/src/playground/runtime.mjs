import { DefaultRubyVM } from '@ruby/wasm-wasi/dist/browser';
import { validateState } from './share.mjs';

function rubyData(value) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = '';
  for (let index = 0; index < bytes.length; index += 4096) binary += String.fromCharCode(...bytes.subarray(index, index + 4096));
  return `JSON.parse(${JSON.stringify(btoa(binary))}.unpack1("m0"))`;
}

export async function createRuntime(binary, assets) {
  const module = await WebAssembly.compile(binary);
  return {
    async run(request, ready = () => {}) {
      validateState(request);
      const start = performance.now();
      const { vm } = await DefaultRubyVM(module, { consolePrint: false });
      vm.eval(`require "json"; require "fileutils"
        ${rubyData(assets.files)}.each do |path, source|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, source)
        end
        $LOAD_PATH.unshift("/app/lib")
        require "flexr/cli"
        require "flexr/trace"
        load "/app/playground.rb"
      `);
      const startupMs = performance.now() - start;
      ready(startupMs);
      const result = JSON.parse(vm.eval(`FlexrPlayground.run(${rubyData(request)})`).toString());
      return { ...result, startup_ms: startupMs };
    },
  };
}
