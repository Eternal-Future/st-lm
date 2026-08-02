FROM ghcr.io/sillytavern/sillytavern:1.18.0

USER root

# 找到官方镜像内预编译的 lib.js。
# 如果不存在，则在镜像构建阶段重新编译。
# 最后复制到 public/lib.js，作为普通静态文件提供。
RUN node --input-type=module -e "\
import fs from 'node:fs'; \
import path from 'node:path'; \
import getWebpackServeMiddleware from './src/middleware/webpack-serve.js'; \
import getPublicLibConfig from './webpack.config.js'; \
const config = getPublicLibConfig({ forceDist: true }); \
const compiledFile = path.join(config.output.path, config.output.filename); \
if (!fs.existsSync(compiledFile)) { \
    console.log('Precompiled lib.js not found. Building it now...'); \
    const middleware = getWebpackServeMiddleware(); \
    await middleware.runWebpackCompiler({ forceDist: true, pruneCache: true }); \
} \
if (!fs.existsSync(compiledFile)) { \
    throw new Error('Compiled lib.js not found: ' + compiledFile); \
} \
fs.copyFileSync(compiledFile, './public/lib.js'); \
const size = fs.statSync('./public/lib.js').size; \
console.log('Prepared public/lib.js: ' + size + ' bytes'); \
"

# 1. 禁用运行时 Webpack 中间件，让 express.static 提供 public/lib.js
# 2. 跳过启动时的 Webpack 编译，避免 512MB OOM
RUN node --input-type=module -e "\
import fs from 'node:fs'; \
const file = './src/server-main.js'; \
let source = fs.readFileSync(file, 'utf8'); \
const serveTarget = 'app.use(webpackMiddleware);'; \
const compileTarget = '    await webpackMiddleware.runWebpackCompiler({ pruneCache: true });'; \
if (!source.includes(serveTarget)) { \
    throw new Error('Webpack middleware target not found'); \
} \
if (!source.includes(compileTarget)) { \
    throw new Error('Webpack compiler target not found'); \
} \
source = source.replace( \
    serveTarget, \
    '// Runtime Webpack middleware disabled; serve public/lib.js statically.' \
); \
source = source.replace( \
    compileTarget, \
    \"    console.log('Using precompiled public/lib.js.');\" \
); \
fs.writeFileSync(file, source); \
"

EXPOSE 8000
