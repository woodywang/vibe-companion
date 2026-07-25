# 部署说明

## 后端 + 网站

### 本地开发

```bash
cd server
cp .env.example .env.local       # 按需修改
npm install
npm run db:push                  # 初始化 SQLite schema（自动建 .data/ 目录）
npm run dev                      # http://localhost:3000
```

SQLite 数据库默认存于 `server/.data/app.db`（已在 `.gitignore`）。

### 生产部署（Vercel + Turso）

SQLite 文件不适合 serverless（无持久磁盘）。生产建议用 Turso（libsql 托管）：

1. 在 [Turso](https://turso.tech) 创建数据库，获取 `libsql://...` 地址和 auth token。
2. 配置环境变量：
   ```
   DATABASE_URL=libsql://your-db.turso.io
   DATABASE_AUTH_TOKEN=eyJhbGciOi...
   AUTH_SECRET=<openssl rand -hex 32>
   ```
   `AUTH_SECRET` 必须在构建和运行环境都设置：`assertAuthSecret` 在 `NODE_ENV=production` 且未设置该变量时会在模块加载时直接抛错，因此 `next build` 和运行时都会因缺失该变量而失败。
3. 部署到 Vercel：
   ```bash
   cd server
   vercel --prod
   ```
4. 推送 schema 到 Turso：
   ```bash
   DATABASE_URL=libsql://... DATABASE_AUTH_TOKEN=... npm run db:push
   ```

### 切换到 PostgreSQL（可选）

schema 用 Drizzle ORM 抽象，迁移步骤：

1. 安装 `drizzle-orm/node-postgres` 与 `pg`，移除 `@libsql/client`。
2. 改 `lib/db/index.ts` 用 `drizzle(pool, { schema })`。
3. `drizzle.config.ts` 的 `dialect` 改为 `"postgresql"`，`dbCredentials` 用 connection string。
4. `lib/usage/queries.ts` 中的 `date()` 函数需适配 Postgres 语法。
5. `npm run db:push` 重建 schema。

## macOS 客户端

### 构建

```bash
# 需先设 Xcode 路径（若 xcode-select 指向 CLT）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 从仓库根目录
./scripts/build-app.sh           # debug 版
./scripts/build-app.sh release   # release 版（优化）
open client/.build/app/VibeCompanion.app
```

### 首次使用

1. 启动 App（菜单栏出现图标，不出现在 Dock，因 `LSUIElement=true`）。
2. 点击菜单栏图标 -> 「⚙ 设置…」。
3. 在网站注册账户 -> 登录 -> Dashboard 点「添加设备」获取 Client Token。
4. 粘贴 Token 到设置页「账户」->「保存 Token 并完成注册」。
5. 修改「服务地址」指向生产后端（默认 `http://localhost:3000`）。
6. 开始用 Claude Code / Codex CLI 编程，悬浮宠物窗会出现并随 token 速率蹬车。

### 签名与公证（生产分发）

MVP 的 `.app` 未签名，首次打开需右键 -> 打开绕过 Gatekeeper。正式分发需：

```bash
codesign --deep --options runtime --sign "Developer ID Application: <Name>" VibeCompanion.app
xcrun notarytool submit VibeCompanion.app.zip --apple-id <apple-id> --team-id <team-id> --wait
xcrun stapler staple VibeCompanion.app
```

并配置 `entitlements.plist`（本场景无需特殊权限，监听 `~/.claude`、`~/.codex` 属用户主目录，不触发 TCC）。

## 数据安全

- `client_token` 明文存于 macOS Keychain（MVP 暂存 UserDefaults，生产应迁 Keychain）。
- 服务端只存 token 的 bcrypt hash，明文仅在注册时返回一次。
- 密码用 bcrypt（cost=10）哈希存储。
- Web 会话用 HS256 JWT，30 天有效期，httpOnly cookie。
