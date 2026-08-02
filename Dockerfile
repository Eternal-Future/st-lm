FROM ghcr.io/sillytavern/sillytavern:1.18.0

USER root

# 安装备份工具和新加坡时区数据
RUN apk add --no-cache rclone tzdata \
    && cp /usr/share/zoneinfo/Asia/Singapore /etc/localtime \
    && echo "Asia/Singapore" > /etc/timezone

ENV TZ=Asia/Singapore

# 查找官方镜像构建时生成的 lib.js。
# 如果找不到，则在镜像构建阶段重新编译。
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
console.log('Prepared public/lib.js: ' + fs.statSync('./public/lib.js').size + ' bytes'); \
"

# 禁用运行时 Webpack：
# 1. 避免 512MB 内存 OOM
# 2. 让 Express 直接提供 public/lib.js
RUN node --input-type=module -e "\
import fs from 'node:fs'; \
const file = './src/server-main.js'; \
let source = fs.readFileSync(file, 'utf8'); \
const serveTarget = 'app.use(webpackMiddleware);'; \
const compileTarget = '    await webpackMiddleware.runWebpackCompiler({ pruneCache: true });'; \
if (!source.includes(serveTarget)) { \
    throw new Error('Webpack middleware patch target not found'); \
} \
if (!source.includes(compileTarget)) { \
    throw new Error('Webpack compiler patch target not found'); \
} \
source = source.replace( \
    serveTarget, \
    '// Runtime Webpack middleware disabled; public/lib.js is served statically.' \
); \
source = source.replace( \
    compileTarget, \
    \"    console.log('Using precompiled public/lib.js.');\" \
); \
fs.writeFileSync(file, source); \
"

# 内置 SillyTavern 配置
COPY --chown=node:node config.yaml /home/node/app/config/config.yaml

# 添加启动、恢复和备份脚本
COPY nf-entrypoint.sh /usr/local/bin/nf-entrypoint.sh
COPY restore.sh /usr/local/bin/restore.sh
COPY backup.sh /usr/local/bin/backup.sh
COPY root.cron /etc/crontabs/root

RUN chmod 0755 \
        /usr/local/bin/nf-entrypoint.sh \
        /usr/local/bin/restore.sh \
        /usr/local/bin/backup.sh \
    && chmod 0600 /etc/crontabs/root

EXPOSE 8000

ENTRYPOINT ["tini", "--", "/usr/local/bin/nf-entrypoint.sh"]
