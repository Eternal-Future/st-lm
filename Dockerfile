FROM ghcr.io/sillytavern/sillytavern:1.18.0

USER root

# 官方镜像已经在构建阶段生成了前端 lib.js。
# 删除启动时重复执行的 Webpack 编译，降低启动内存峰值。
RUN node --input-type=module -e "\
import fs from 'node:fs'; \
const file = './src/server-main.js'; \
const source = fs.readFileSync(file, 'utf8'); \
const target = '    await webpackMiddleware.runWebpackCompiler({ pruneCache: true });'; \
const replacement = \"    console.log('Using precompiled frontend libraries from Docker image.');\"; \
if (!source.includes(target)) { \
    throw new Error('Patch target not found. SillyTavern source may have changed.'); \
} \
fs.writeFileSync(file, source.replace(target, replacement)); \
"

EXPOSE 8000
