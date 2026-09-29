# moonpainter-sdk

MoonPainter 引擎的 JS 宿主胶水（wasm 加载器 + 类型化门面）。引擎本体 100% MoonBit，
本包只是宿主侧适配器：加载 `moonpainter.wasm`、字符串槽编解码、JSON 信封解析。

```js
import { loadEngine } from './index.js';
const mp = await loadEngine('./moonpainter.wasm');

await mp.exec('session-open full_image');   // vision 闸（引擎硬性前置）
mp.exec('new 640 480 uuid=demo');
mp.exec('add-rect x=0 y=0 w=640 h=480 fill=#1B2A41FF');
const r = mp.render(480);
// r.png_b64 → <img src="data:image/png;base64,">
const saved = mp.saveMpd();                 // .mpd 容器 base64
```

多会话：

```js
const h = mp.open();                        // 句柄会话
mp.execOn(h, 'new 100 100 uuid=second');
mp.close(h);
```

构建 wasm：仓库根目录 `moon build --target wasm`（或 `./build_demo.sh`），
产物 `target/wasm/.../wasm.wasm` 复制为本包 `moonpainter.wasm`。
