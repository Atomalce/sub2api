# Type Safety

> 前端 TypeScript 类型安全规范。内部项目精简版。

---

## Overview

- TypeScript `~5.6.0` + `vue-tsc`,全程 `strict: true`。
- 类型检查有三道关卡,任何一道报错都视为不通过:
  1. 开发时:`vite-plugin-checker`(`checker({ vueTsc: true })`,见 `frontend/vite.config.ts`)实时报错;
  2. 手动:`pnpm typecheck`(= `vue-tsc --noEmit`);
  3. 构建:`pnpm build` 先跑 `vue-tsc -b`,类型错误直接导致构建失败。
- 无运行时校验库(没有 Zod/Yup);API 边界的运行时防御靠手写结构检查(见 Validation 一节)。
- 测试文件(`__tests__/`、`*.spec.ts`、`*.test.ts`)被 `tsconfig.json` 的 `exclude` 排除在类型检查之外,Vitest 运行时也不做类型检查——测试里的类型错误不会被 CI 类型关卡拦截,写测试时自觉保持类型正确。

---

## tsconfig Strictness

`frontend/tsconfig.json` 关键开关(改动需团队评审,只允许收紧不允许放松):

| 选项 | 值 | 影响 |
|------|-----|------|
| `strict` | `true` | 含 `strictNullChecks`,可空字段必须显式 `?` 或 `\| null` |
| `noUnusedLocals` / `noUnusedParameters` | `true` | 未使用变量/参数导致构建失败;故意忽略的参数用 `_` 前缀(ESLint `argsIgnorePattern: "^_"`) |
| `noFallthroughCasesInSwitch` | `true` | switch 分支必须 break/return |
| `isolatedModules` | `true` | 纯类型导出必须用 `export type` / `import type` |
| `paths` | `"@/*": ["./src/*"]` | 跨目录导入一律用 `@/` 别名,不写 `../../` |

---

## Type Organization

类型定义位置按作用域分三层:

1. **共享域类型** → `frontend/src/types/index.ts`(单文件集中管理,约 2000 行):`User`、`ApiKey`、`Group`、`ApiResponse<T>`、`PaginatedResponse<T>` 等所有跨模块复用的实体与请求/响应类型。
2. **独立子域** → 仅当子域足够大时才拆文件,目前只有 `frontend/src/types/payment.ts`(支付订单/渠道类型)。不要为几个类型新开文件。
3. **模块私有类型** → 就近定义在使用它的模块内,不进 `types/`。例如 `frontend/src/api/admin/ops.ts` 顶部定义 `OpsDashboardOverview`、`OpsRequestDetailsParams` 等仅 Ops 页面使用的类型。

全局声明:

- `frontend/src/types/global.d.ts`:Window 扩展(`window.__APP_CONFIG__?: PublicSettings`);
- `frontend/src/vite-env.d.ts`:`ImportMetaEnv`、`*.vue` / `*.md?raw` 模块声明。

导入纯类型时必须 `import type`(`isolatedModules` 要求):

```ts
// frontend/src/api/keys.ts
import type { ApiKey, CreateApiKeyRequest, UpdateApiKeyRequest, PaginatedResponse } from '@/types'
```

联合字面量优先于 string,与后端枚举一一对应:

```ts
// frontend/src/types/payment.ts
export type PaymentType = 'alipay' | 'wxpay' | 'alipay_direct' | 'wxpay_direct' | 'stripe' | 'easypay' | 'airwallex'
```

---

## API Response Typing

后端统一响应信封 `{ code, message, data }` 定义在 `frontend/src/types/index.ts`:

```ts
export interface ApiResponse<T = unknown> {
  code: number
  message: string
  data: T
}

export interface PaginatedResponse<T> {
  items: T[]
  total: number
  page: number
  page_size: number
  pages: number
}
```

`frontend/src/api/client.ts` 的响应拦截器负责解包:`code === 0` 时把 `response.data` 替换为 `data` 字段。因此 **API 函数的泛型标注的是解包后的业务数据**,不是信封:

```ts
// frontend/src/api/keys.ts
export async function list(...): Promise<PaginatedResponse<ApiKey>> {
  const { data } = await apiClient.get<PaginatedResponse<ApiKey>>('/keys', { ... })
  return data
}
```

约定:

- 每个 API 函数必须显式标注返回类型 `Promise<具体类型>`,禁止 `Promise<any>`(当前代码 0 处,保持)。
- 列表接口一律返回 `PaginatedResponse<T>`。
- API 模块导出模式:具名函数 + 聚合对象(`export const keysAPI = { list, getById, ... }`),经 `frontend/src/api/index.ts` 统一再导出。

---

## Validation

无 Zod/Yup。运行时防御只发生在 axios 拦截器这一处边界,采用手写结构检查 + `unknown` 收窄:

```ts
// frontend/src/api/client.ts
const apiResponse = response.data as ApiResponse<unknown>
if (apiResponse && typeof apiResponse === 'object' && 'code' in apiResponse) { ... }

// 错误分支:防止 HTML 错误页破坏错误处理
const apiData = (typeof data === 'object' && data !== null ? data : {}) as Record<string, any>
```

除拦截器外,业务代码默认信任 `types/index.ts` 中的类型即后端真实返回;后端字段变更时必须同步改类型定义。

---

## Vue Component & Composable Typing

组件 props/emits 一律用类型泛型形式(不用运行时对象声明):

```ts
// frontend/src/components/common/PlatformIcon.vue
const props = withDefaults(defineProps<Props>(), { ... })

// frontend/src/components/admin/channel/ModelTagInput.vue
const props = defineProps<{ ... }>()
const emit = defineEmits<{ ... }>()
```

Composable(`frontend/src/composables/`)接受/返回类型明确,复用逻辑用泛型参数:

```ts
// frontend/src/composables/useForm.ts
interface UseFormOptions<T> {
  form: T
  submitFn: (data: T) => Promise<void>
  successMsg?: string
}
export function useForm<T>(options: UseFormOptions<T>) { ... }
```

`catch (error: any)` 是既有的错误处理惯用法(拦截器 reject 的是普通对象,无共享错误类型),允许沿用,但仅限 catch 块内取 `message`/`code` 字段,不得把该 `any` 继续外传。

---

## The Stance on `any`

现状:ESLint 关闭了 `@typescript-eslint/no-explicit-any`(见 `frontend/.eslintrc.cjs`),存量代码约 340 处 `: any`。态度是"容忍存量、限制增量":

- **允许**:`catch (error: any)`;第三方库类型缺失处的局部 `any`(需注释原因);存量代码顺手重构时不强制清理。
- **不允许新增**:`src/types/` 中的接口字段类型、API 函数签名(参数与返回值)、composable 的对外签名。
- 类型未知时优先 `unknown` + 收窄,参考 `client.ts` 中 `as ApiResponse<unknown>`、`Record<string, unknown>` 的用法。
- 需要开放扩展字段时用注明理由的索引签名,而不是整体 `any`:

```ts
// frontend/src/types/index.ts
export interface SelectOption {
  value: string | number | boolean | null
  label: string
  [key: string]: any // Support extra properties for custom templates
}
```

---

## Type Check Commands

```bash
pnpm typecheck    # vue-tsc --noEmit,提交前必跑
pnpm build        # vue-tsc -b && vite build,类型错误 = 构建失败
pnpm lint:check   # ESLint(不含类型检查)
pnpm test:run     # Vitest(不做类型检查,注意)
```

---

## Forbidden Patterns

- **`@ts-ignore` / `@ts-expect-error` / `@ts-nocheck`** — 当前代码 0 处,保持为零。类型报错要修类型,不许压制(ESLint 虽关闭了 `ban-ts-comment`,但这是团队约定)。
- **`Promise<any>` 作为 API 函数返回类型** — 必须写出具体业务类型。
- **绕过 `apiClient` 使用裸 `axios`** — 会丢失响应解包、token 刷新、错误规整。唯一例外是 `client.ts` 内部的 `/auth/refresh` 调用(避免循环依赖,已有注释说明)。
- **在 `src/types/index.ts` 新增字段用 `any`** — 共享类型是全前端的契约,必须精确。
- **相对路径跨目录导入(`../../types`)** — 一律 `@/types`。
- **`export` 纯类型不加 `type` 关键字** — `isolatedModules` 下可能编译报错,统一 `export type` / `import type`。
- **为绕过 `noUnusedLocals` 而删除类型标注或改用 `any`** — 未使用项要么删除,要么 `_` 前缀。
- **放松 `tsconfig.json` 严格选项**(如关 `strict`、加 `suppressImplicitAnyIndexErrors`)— 只能收紧。
