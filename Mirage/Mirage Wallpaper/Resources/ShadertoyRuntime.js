(() => {
  "use strict";

  const canvas = document.getElementById("mirage-shader-canvas");
  const errorPanel = document.getElementById("mirage-shader-error");

  function report(type, message) {
    document.documentElement.dataset.mirageShaderStatus = type;
    document.documentElement.dataset.mirageShaderMessage = message || "";
    if (type === "error") {
      errorPanel.hidden = false;
      errorPanel.textContent = message || "Shader 运行失败";
    } else if (type === "ready") {
      errorPanel.hidden = true;
      errorPanel.textContent = "";
    }
    try {
      const handler = window.webkit && window.webkit.messageHandlers &&
        window.webkit.messageHandlers.mirageShaderPreview;
      if (handler) handler.postMessage({ type, message: message || "" });
    } catch (_) {}
  }

  window.addEventListener("error", event => {
    report("error", `运行时错误：${event.message || "未知错误"}`);
  });
  window.addEventListener("unhandledrejection", event => {
    const reason = event.reason && (event.reason.message || event.reason);
    report("error", `异步运行错误：${reason || "未知错误"}`);
  });

  function decodeConfig() {
    const encoded = window.__MIRAGE_SHADER_CONFIG_B64;
    if (!encoded) throw new Error("缺少 Shader 配置");
    const bytes = Uint8Array.from(atob(encoded), value => value.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes));
  }

  let config;
  try {
    config = decodeConfig();
  } catch (error) {
    report("error", `配置读取失败：${error.message || error}`);
    return;
  }

  const gl = canvas.getContext("webgl2", {
    alpha: false,
    antialias: false,
    depth: false,
    stencil: false,
    preserveDrawingBuffer: true,
    powerPreference: "high-performance"
  });
  if (!gl) {
    report("error", "当前系统无法创建 WebGL 2 上下文");
    return;
  }

  const vertexSource = `#version 300 es
  precision highp float;
  void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
  }`;

  const uniformHeader = `
  precision highp float;
  precision highp int;
  uniform vec3 iResolution;
  uniform float iTime;
  uniform float iTimeDelta;
  uniform float iFrameRate;
  uniform int iFrame;
  uniform vec4 iMouse;
  uniform vec4 iDate;
  uniform float iSampleRate;
  uniform float iChannelTime[4];
  uniform vec3 iChannelResolution[4];
  uniform sampler2D iChannel0;
  uniform sampler2D iChannel1;
  uniform sampler2D iChannel2;
  uniform sampler2D iChannel3;
  out vec4 mirageFragColor;
  #define texture2D texture
  `;

  function preparedSource(source) {
    const extensions = [];
    const body = String(source || "")
      .replace(/^\uFEFF/, "")
      .replace(/^\s*#version[^\n]*(?:\n|$)/gm, "")
      .replace(/^\s*#extension[^\n]*(?:\n|$)/gm, directive => {
        extensions.push(directive.trim());
        return "";
      });
    return { body, extensions };
  }

  function fragmentSource(pass) {
    const common = preparedSource(config.commonCode);
    const code = preparedSource(pass.code);
    const extensions = [...new Set([...common.extensions, ...code.extensions])].join("\n");
    return `#version 300 es\n${extensions}\n${uniformHeader}\n#line 1\n${common.body}\n#line 1\n${code.body}\n` +
      `void main() { mainImage(mirageFragColor, gl_FragCoord.xy); }\n`;
  }

  function compileShader(type, source, label) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(shader) || "未知编译错误";
      gl.deleteShader(shader);
      throw new Error(`${label}\n${log}`);
    }
    return shader;
  }

  const vertexShader = (() => {
    try {
      return compileShader(gl.VERTEX_SHADER, vertexSource, "全屏顶点着色器");
    } catch (error) {
      report("error", error.message || String(error));
      return null;
    }
  })();
  if (!vertexShader) return;

  function createProgram(pass) {
    const fragmentShader = compileShader(
      gl.FRAGMENT_SHADER,
      fragmentSource(pass),
      `${pass.name || pass.id} 编译失败`
    );
    const program = gl.createProgram();
    gl.attachShader(program, vertexShader);
    gl.attachShader(program, fragmentShader);
    gl.linkProgram(program);
    gl.deleteShader(fragmentShader);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      const log = gl.getProgramInfoLog(program) || "未知链接错误";
      gl.deleteProgram(program);
      throw new Error(`${pass.name || pass.id} 链接失败\n${log}`);
    }
    const uniform = name => gl.getUniformLocation(program, name);
    return {
      definition: pass,
      program,
      uniforms: {
        resolution: uniform("iResolution"),
        time: uniform("iTime"),
        timeDelta: uniform("iTimeDelta"),
        frameRate: uniform("iFrameRate"),
        frame: uniform("iFrame"),
        mouse: uniform("iMouse"),
        date: uniform("iDate"),
        sampleRate: uniform("iSampleRate"),
        channelTime: uniform("iChannelTime[0]"),
        channelResolution: uniform("iChannelResolution[0]"),
        channels: [0, 1, 2, 3].map(index => uniform(`iChannel${index}`))
      }
    };
  }

  const renderPasses = [];
  try {
    for (const pass of config.passes || []) renderPasses.push(createProgram(pass));
  } catch (error) {
    report("error", error.message || String(error));
    return;
  } finally {
    gl.deleteShader(vertexShader);
  }

  if (!renderPasses.some(pass => pass.definition.id === "image")) {
    report("error", "缺少 Image Pass");
    return;
  }

  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);

  function createTexture(width, height, data, options = {}) {
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, options.filter || gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, options.filter || gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, options.wrap || gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, options.wrap || gl.CLAMP_TO_EDGE);
    gl.texImage2D(
      gl.TEXTURE_2D, 0, options.internalFormat || gl.RGBA8,
      width, height, 0, options.format || gl.RGBA,
      options.type || gl.UNSIGNED_BYTE, data
    );
    return texture;
  }

  const blackTexture = createTexture(1, 1, new Uint8Array([0, 0, 0, 255]), {
    filter: gl.NEAREST,
    wrap: gl.CLAMP_TO_EDGE
  });

  function createNoiseTexture() {
    const size = 1024;
    const bytes = new Uint8Array(size * size * 4);
    let seed = 0x6d697261;
    for (let index = 0; index < size * size; index += 1) {
      seed ^= seed << 13;
      seed ^= seed >>> 17;
      seed ^= seed << 5;
      const offset = index * 4;
      bytes[offset] = seed & 255;
      bytes[offset + 1] = (seed >>> 8) & 255;
      bytes[offset + 2] = (seed >>> 16) & 255;
      bytes[offset + 3] = 255;
    }
    return {
      texture: createTexture(size, size, bytes, { filter: gl.LINEAR, wrap: gl.REPEAT }),
      width: size,
      height: size,
      ready: true
    };
  }

  const noiseTexture = createNoiseTexture();
  const imageTextures = new Map();

  function imageTextureFor(channel) {
    const key = channel.url || "";
    if (imageTextures.has(key)) return imageTextures.get(key);
    const record = { texture: blackTexture, width: 1, height: 1, ready: false };
    imageTextures.set(key, record);
    if (!key) return record;

    const image = new Image();
    image.decoding = "async";
    image.onload = () => {
      const texture = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, channel.flipY !== false);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      record.texture = texture;
      record.width = image.naturalWidth || image.width || 1;
      record.height = image.naturalHeight || image.height || 1;
      record.ready = true;
    };
    image.onerror = () => {
      console.error(`Mirage Shader: 无法载入纹理 ${key}`);
    };
    image.src = key;
    return record;
  }

  for (const pass of renderPasses) {
    for (const channel of pass.definition.channels || []) {
      if (channel.kind === "texture") imageTextureFor(channel);
    }
  }

  const buffers = new Map();
  let surfaceWidth = 0;
  let surfaceHeight = 0;
  const floatBufferSupported = !!gl.getExtension("EXT_color_buffer_float");

  function deleteBufferState(state) {
    if (!state) return;
    for (const texture of state.textures) gl.deleteTexture(texture);
    for (const framebuffer of state.framebuffers) gl.deleteFramebuffer(framebuffer);
  }

  function makeBufferAttachment(width, height) {
    const preferred = floatBufferSupported
      ? { internalFormat: gl.RGBA16F, format: gl.RGBA, type: gl.HALF_FLOAT }
      : { internalFormat: gl.RGBA8, format: gl.RGBA, type: gl.UNSIGNED_BYTE };
    const texture = createTexture(width, height, null, preferred);
    const framebuffer = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
    if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
      gl.deleteFramebuffer(framebuffer);
      gl.deleteTexture(texture);
      const fallbackTexture = createTexture(width, height, null);
      const fallbackFramebuffer = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, fallbackFramebuffer);
      gl.framebufferTexture2D(
        gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, fallbackTexture, 0
      );
      return { texture: fallbackTexture, framebuffer: fallbackFramebuffer };
    }
    return { texture, framebuffer };
  }

  function rebuildBuffers(width, height) {
    for (const state of buffers.values()) deleteBufferState(state);
    buffers.clear();
    for (const pass of renderPasses) {
      if (pass.definition.id === "image") continue;
      const first = makeBufferAttachment(width, height);
      const second = makeBufferAttachment(width, height);
      const state = {
        textures: [first.texture, second.texture],
        framebuffers: [first.framebuffer, second.framebuffer],
        front: 0,
        width,
        height
      };
      buffers.set(pass.definition.id, state);
      for (const framebuffer of state.framebuffers) {
        gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
        gl.viewport(0, 0, width, height);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
      }
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  }

  function resizeIfNeeded() {
    const scale = Math.min(1, Math.max(0.25, Number(config.renderScale) || 1));
    const dpr = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
    let width = Math.max(1, Math.floor(canvas.clientWidth * dpr * scale));
    let height = Math.max(1, Math.floor(canvas.clientHeight * dpr * scale));
    const maxDimension = Math.min(8192, Math.max(512, Number(config.maxDimension) || 4096));
    const shrink = Math.min(1, maxDimension / Math.max(width, height));
    width = Math.max(1, Math.floor(width * shrink));
    height = Math.max(1, Math.floor(height * shrink));
    if (width === surfaceWidth && height === surfaceHeight) return false;
    surfaceWidth = width;
    surfaceHeight = height;
    canvas.width = width;
    canvas.height = height;
    rebuildBuffers(width, height);
    return true;
  }

  function applySampling(texture, channel) {
    gl.bindTexture(gl.TEXTURE_2D, texture);
    const filter = channel.filter === "nearest" ? gl.NEAREST : gl.LINEAR;
    const wrap = channel.wrap === "clamp" ? gl.CLAMP_TO_EDGE : gl.REPEAT;
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrap);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrap);
  }

  function resolveChannel(channel) {
    if (!channel || channel.kind === "none") {
      return { texture: blackTexture, width: 1, height: 1 };
    }
    if (channel.kind === "noise") return noiseTexture;
    if (channel.kind === "texture") return imageTextureFor(channel);
    if (channel.kind === "buffer") {
      const state = buffers.get(channel.source);
      if (state) {
        return {
          texture: state.textures[state.front],
          width: state.width,
          height: state.height
        };
      }
    }
    return { texture: blackTexture, width: 1, height: 1 };
  }

  const mouse = new Float32Array([0, 0, -1, -1]);
  let mouseDown = false;

  function pointerPosition(event) {
    const rect = canvas.getBoundingClientRect();
    const x = ((event.clientX - rect.left) / Math.max(1, rect.width)) * surfaceWidth;
    const y = (1 - (event.clientY - rect.top) / Math.max(1, rect.height)) * surfaceHeight;
    return [Math.max(0, Math.min(surfaceWidth, x)), Math.max(0, Math.min(surfaceHeight, y))];
  }

  canvas.addEventListener("mousemove", event => {
    const [x, y] = pointerPosition(event);
    mouse[0] = x;
    mouse[1] = y;
  });
  canvas.addEventListener("mousedown", event => {
    const [x, y] = pointerPosition(event);
    mouseDown = true;
    mouse[0] = x;
    mouse[1] = y;
    mouse[2] = x;
    mouse[3] = y;
  });
  window.addEventListener("mouseup", event => {
    const [x, y] = pointerPosition(event);
    mouseDown = false;
    mouse[0] = x;
    mouse[1] = y;
    mouse[2] = -Math.abs(mouse[2]);
    mouse[3] = -Math.abs(mouse[3]);
  });

  let hostPaused = false;
  let elapsed = 0;
  let frame = 0;
  let lastTimestamp = 0;
  let lastDrawTimestamp = 0;

  window.wallpaperPropertyListener = {
    setPaused(value) {
      hostPaused = !!value;
      lastTimestamp = 0;
      lastDrawTimestamp = 0;
    }
  };

  document.addEventListener("visibilitychange", () => {
    lastTimestamp = 0;
    lastDrawTimestamp = 0;
  });

  function setUniforms(pass, delta, frameRate) {
    const u = pass.uniforms;
    if (u.resolution) gl.uniform3f(u.resolution, surfaceWidth, surfaceHeight, 1);
    if (u.time) gl.uniform1f(u.time, elapsed);
    if (u.timeDelta) gl.uniform1f(u.timeDelta, delta);
    if (u.frameRate) gl.uniform1f(u.frameRate, frameRate);
    if (u.frame) gl.uniform1i(u.frame, frame);
    if (u.mouse) gl.uniform4fv(u.mouse, mouse);
    if (u.sampleRate) gl.uniform1f(u.sampleRate, 44100);
    if (u.channelTime) gl.uniform1fv(u.channelTime, new Float32Array([elapsed, elapsed, elapsed, elapsed]));

    const now = new Date();
    const seconds = now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds() + now.getMilliseconds() / 1000;
    if (u.date) gl.uniform4f(u.date, now.getFullYear(), now.getMonth() + 1, now.getDate(), seconds);

    const resolutions = new Float32Array(12);
    const channels = pass.definition.channels || [];
    for (let index = 0; index < 4; index += 1) {
      const channel = channels[index] || { kind: "none" };
      const resolved = resolveChannel(channel);
      gl.activeTexture(gl.TEXTURE0 + index);
      applySampling(resolved.texture, channel);
      if (u.channels[index]) gl.uniform1i(u.channels[index], index);
      resolutions[index * 3] = resolved.width || 1;
      resolutions[index * 3 + 1] = resolved.height || 1;
      resolutions[index * 3 + 2] = 1;
    }
    if (u.channelResolution) gl.uniform3fv(u.channelResolution, resolutions);
  }

  function drawPass(pass, delta, frameRate) {
    let outputState = null;
    let outputIndex = 0;
    if (pass.definition.id === "image") {
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    } else {
      outputState = buffers.get(pass.definition.id);
      if (!outputState) return;
      outputIndex = 1 - outputState.front;
      gl.bindFramebuffer(gl.FRAMEBUFFER, outputState.framebuffers[outputIndex]);
    }
    gl.viewport(0, 0, surfaceWidth, surfaceHeight);
    gl.useProgram(pass.program);
    setUniforms(pass, delta, frameRate);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    if (outputState) outputState.front = outputIndex;
  }

  let reportedReady = false;
  function render(timestamp) {
    requestAnimationFrame(render);
    if (hostPaused) return;
    const fpsLimit = Math.min(120, Math.max(1, Number(config.fpsLimit) || 60));
    const interval = 1000 / fpsLimit;
    if (lastDrawTimestamp && timestamp - lastDrawTimestamp < interval - 0.5) return;

    resizeIfNeeded();
    const delta = lastTimestamp ? Math.min(0.25, Math.max(0, (timestamp - lastTimestamp) / 1000)) : 0;
    lastTimestamp = timestamp;
    lastDrawTimestamp = timestamp;
    elapsed += delta;
    const frameRate = delta > 0 ? 1 / delta : fpsLimit;

    for (const pass of renderPasses) drawPass(pass, delta, frameRate);
    frame += 1;
    if (!reportedReady && frame >= 1) {
      reportedReady = true;
      report("ready", "Shader 编译成功");
    }
  }

  resizeIfNeeded();
  // Draw one frame synchronously. WKWebView may suspend requestAnimationFrame
  // while its host app is temporarily not frontmost (for example during a
  // SwiftUI sheet transition), but compile feedback and the static preview
  // should still be available immediately.
  render(performance.now());
})();
