# Directory Structure

> 前端目录组织规范。内部项目精简版。

---

## Overview

- 前端全部位于 `frontend/`,技术栈:Vue 3(组合式 API)+ TypeScript + Vite + Pinia + vue-router + Tailwind CSS + vue-i18n,包管理 pnpm 9,测试 Vitest。
- `src/` 按**技术角色分层**(api / views / components / stores / composables / utils),不按业务 feature 分包;业务域体现在各层的子目录(如 `components/keys/`、`api/admin/`)。
- 路径别名 `@` → `frontend/src`(见 `frontend/vite.config.ts`),所有跨目录导入一律用 `@/`。
- 单元测试与被测代码同层,放在同级 `__tests__/` 目录,命名 `*.spec.ts`(vitest include:`src/**/*.{test,spec}.{js,ts,jsx,tsx}`,见 `frontend/vitest.config.ts`)。

---

## Directory Layout

```
frontend/src/
├── main.ts               # 入口:createApp + pinia + router + i18n
├── App.vue               # 根组件
├── api/                  # HTTP 层,唯一允许发请求的地方
│   ├── client.ts         # axios 实例 + 拦截器(token 注入/刷新、Accept-Language、timezone)
│   ├── url.ts            # baseURL / buildApiUrl / buildGatewayUrl
│   ├── index.ts          # 桶导出:keysAPI、usageAPI、adminAPI 等
│   ├── keys.ts …         # 用户端 API 模块,一个业务域一个文件
│   └── admin/            # 管理端 API 模块,由 admin/index.ts 聚合为 adminAPI
├── views/                # 路由页面组件(与 router/index.ts 一一对应)
│   ├── HomeView.vue      # 顶层:少量公共页(Home/KeyUsage/NotFound)
│   ├── auth/             # 登录/注册/各 OAuth 回调页
│   ├── user/             # 用户端页面(+ 页面私有 .ts 辅助模块可同目录放置)
│   ├── admin/            # 管理端页面(含 affiliates/、ops/、orders/ 子目录)
│   ├── public/           # 无需登录的公开页(LegalDocumentView)
│   └── setup/            # 初始化安装向导
├── components/           # 非路由组件,按业务域分子目录
│   ├── common/           # 跨域通用组件(DataTable、BaseDialog、Toast…),经 index.ts 导出
│   ├── layout/           # AppLayout / AppHeader / AppSidebar / AuthLayout
│   ├── admin/ keys/ …    # 域组件:account、auth、channels、charts、payment、user 等
├── composables/          # 组合式函数,一个能力一个 useXxx.ts
├── stores/               # Pinia store(auth、app、adminSettings…),经 index.ts 导出
├── router/               # index.ts(全部路由+守卫)、meta.d.ts、setupRedirect.ts、title.ts
├── i18n/                 # index.ts(懒加载 locale)+ locales/{en,zh}/ 按域拆分的消息文件
├── types/                # 全局共享类型(index.ts、payment.ts、global.d.ts)
├── constants/            # 业务常量(account.ts、channel.ts、channelMonitor.ts)
├── utils/                # 纯函数工具,无 Vue 依赖(format.ts、pricing.ts、sanitize.ts…)
├── assets/icons/         # 静态资源
├── styles/               # 补充 CSS(onboarding.css);全局样式在 src/style.css
└── __tests__/            # 跨模块集成测试(integration/)
```

---

## Module Organization

### 新增页面(View)

1. 在 `views/{user|admin|auth|public}/` 下创建 `XxxView.vue`(管理端子域较多时可再建子目录,如 `views/admin/orders/`)。
2. 在 `router/index.ts` 的对应注释分区(Setup / Public / User / Admin / Payment Admin)追加路由,**必须懒加载**并声明 meta,实例摘自 `frontend/src/router/index.ts`:

```ts
{
  path: '/keys',
  name: 'Keys',
  component: () => import('@/views/user/KeysView.vue'),
  meta: { requiresAuth: true, requiresAdmin: false, title: 'API Keys',
          titleKey: 'keys.title', descriptionKey: 'keys.description' }
}
```

3. 页面私有、不被复用的纯逻辑可拆为同目录 `.ts` 文件(现状:`views/user/paymentUx.ts`、`views/admin/groupsModelsList.ts`)。

### 新增组件

- 只被单一业务域使用 → `components/<域>/`(如 `components/keys/UseKeyModal.vue`)。
- 跨域复用 → `components/common/`,并在 `components/common/index.ts` 中追加导出。
- 布局类 → `components/layout/`。
- views/ 下只放路由页面;可复用 UI 一律放 components/。

### 新增接口调用(API)

- 所有 HTTP 请求必须经过 `@/api` 层,组件/store 内不得直接 import axios。
- 用户端:在 `api/` 新建 `<域>.ts`,函数用 `apiClient` 发请求,文件末尾聚合为 `xxxAPI` 命名空间对象并 default 导出,再在 `api/index.ts` 注册。模式摘自 `frontend/src/api/keys.ts`:

```ts
import { apiClient } from './client'

export async function list(page = 1, pageSize = 10, filters?, options?): Promise<PaginatedResponse<ApiKey>> {
  const { data } = await apiClient.get<PaginatedResponse<ApiKey>>('/keys', {
    params: { page, page_size: pageSize, ...filters }, signal: options?.signal })
  return data
}

export const keysAPI = { list, getById, create, update, delete: deleteKey, toggleStatus }
export default keysAPI
```

- 管理端:在 `api/admin/` 新建模块,并在 `api/admin/index.ts` 中并入统一的 `adminAPI` 对象。
- 调用方从桶导入:`import { keysAPI, adminAPI } from '@/api'`(实例:`frontend/src/views/user/KeysView.vue`)。

### 新增全局状态 / Composable

- 跨页面共享的状态 → `stores/xxx.ts`(Pinia),并在 `stores/index.ts` 导出;详见 state-management.md。
- 可复用的响应式逻辑(无全局状态)→ `composables/useXxx.ts`;详见 hook-guidelines.md(本项目即 Composables 规范)。

### 类型 / 常量 / 工具 / i18n

- 跨模块共享类型 → `types/index.ts`;仅单个 API 模块使用的类型可定义在该 API 文件内并具名导出(如 `api/redeem.ts` 的 `RedeemHistoryItem`)。
- 纯函数(无 Vue、无副作用)→ `utils/`;业务枚举常量 → `constants/`。
- 文案改动必须同时更新 `i18n/locales/en/` 与 `i18n/locales/zh/` 对应域文件,两边 key 保持一致。

---

## Routing Organization

- 全部路由集中定义在 `router/index.ts` 的一个扁平 `RouteRecordRaw[]` 中,不使用嵌套 children,按注释分区(Setup → Public → User → Admin → Payment Admin → 404)。
- meta 约定(类型见 `frontend/src/router/meta.d.ts`):
  - `requiresAuth`:缺省视为 `true`(守卫中 `to.meta.requiresAuth !== false`),公开页必须显式写 `false`。
  - `requiresAdmin`:管理端页面为 `true`,守卫不满足时重定向 `/dashboard`。
  - `titleKey` / `descriptionKey`:i18n key,用于文档标题与页头;`title` 为英文兜底。
  - `requiresPayment` / `requiresRiskControl`:功能开关路由,由公共设置(`appStore.cachedPublicSettings`)控制可达性。
- 导航守卫、后端模式(backend mode)路径白名单、chunk 加载失败自动刷新等逻辑全部集中在 `router/index.ts`,新路由只加声明,不在守卫里加针对单页面的特判(功能开关走 meta)。

---

## Naming Conventions

| 内容 | 规则 | 实例 |
|---|---|---|
| 路由页面 | PascalCase + `View` 后缀 | `views/user/KeysView.vue` |
| 组件 | PascalCase `.vue` | `components/common/DataTable.vue` |
| Composable | `use` 前缀 camelCase | `composables/useClipboard.ts` |
| api / stores / utils 模块 | camelCase `.ts` | `api/channelMonitor.ts`、`stores/adminSettings.ts` |
| API 命名空间对象 | `<域>API` | `keysAPI`、`adminAPI` |
| 测试 | 同级 `__tests__/` + `*.spec.ts` | `api/__tests__/client.spec.ts` |

---

## Forbidden Patterns

- **禁止绕过 `@/api` 直接发请求**:组件、store、composable 中不得 `import axios` 或使用 `fetch` 调后端(`api/client.ts` 的拦截器承载 token 刷新/多语言/时区逻辑,绕过即失效)。
- **禁止静态导入 View 组件注册路由**:路由 `component` 必须为 `() => import(...)` 懒加载。
- **禁止在 `router/index.ts` 之外注册路由**或运行时 `addRoute`。
- **禁止在 `views/` 放可复用组件**,禁止在 `components/` 放路由页面。
- **禁止 `utils/` 依赖 Vue 或 store**:需要响应式/生命周期的逻辑属于 `composables/`。
- **禁止相对路径跨目录深层导入**(如 `../../api/keys`),统一 `@/` 别名;同目录内相对导入允许(如 `./client`)。
- **禁止只改单一语言的 i18n 文件**:en / zh 必须同步。
- **禁止把测试文件与源码混放**:一律进同级 `__tests__/`。

---

## Examples

- API 模块范式:`frontend/src/api/keys.ts`(函数 + 命名空间对象聚合)。
- 管理端 API 聚合:`frontend/src/api/admin/index.ts`。
- 复杂页面 + 私有辅助模块:`frontend/src/views/user/KeysView.vue` 与同目录 `paymentUx.ts`。
- 通用组件及桶导出:`frontend/src/components/common/DataTable.vue`、`components/common/index.ts`。
- 路由 meta 与守卫:`frontend/src/router/index.ts`。
