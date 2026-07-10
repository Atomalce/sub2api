# Composable Guidelines

> Vue 3 组合式函数(composables)规范。内部项目精简版。

---

## Overview

- 所有可复用的组合式函数统一放在 `frontend/src/composables/`,**扁平目录、一文件一 composable**,不建子目录。
- 现有约 20 个 composable,典型职责:表格加载(`useTableLoader`)、多选(`useTableSelection`)、剪贴板(`useClipboard`)、表单提交(`useForm`)、自动刷新(`useAutoRefresh`)、各平台 OAuth 流程(`useGrokOAuth` / `useGeminiOAuth` / `useOpenAIOAuth` 等)。
- 单元测试放在 `frontend/src/composables/__tests__/`,文件名 `useXxx.spec.ts`,使用 Vitest。
- 职责边界:
  - **跨组件全局状态** → Pinia store(`frontend/src/stores/`),不写成 composable;
  - **无状态纯函数** → `frontend/src/utils/`;
  - **有响应式状态或生命周期、但按调用方隔离的逻辑** → composable。

---

## Naming Conventions

| 项目 | 约定 | 示例 |
|------|------|------|
| 文件名 | `useXxx.ts`,camelCase,与主导出函数同名 | `useTableLoader.ts` |
| 主导出 | `export function useXxx(...)`,命名导出,不用 default | `export function useClipboard()` |
| 附属导出 | 同域的纯函数/常量可与 composable 同文件导出 | `usePersistedPageSize.ts` 导出 `getPersistedPageSize` / `setPersistedPageSize` |
| Options 接口 | `UseXxxOptions`,定义在同文件内 | `UseAutoRefreshOptions` |
| 测试专用导出 | 下划线前缀 | `_resetNavigationLoadingInstance`(useNavigationLoading.ts) |

---

## When to Extract a Composable

满足任一条件即抽取:

1. **两个以上 view/component 复用**同一段有状态逻辑(如 `useClipboard` 被多个 view 引用)。
2. 逻辑包含**响应式状态 + 生命周期清理**(定时器、AbortController、事件监听),即使暂时只有一处使用(如 `useSwipeSelect`)。
3. **按平台平行扩展**的流程逻辑:每个 OAuth 平台一个独立 composable,不合并成带 if/else 的巨型函数(`useGrokOAuth` / `useGeminiOAuth` / `useAntigravityOAuth` 各自成文件)。

不抽取:仅单个组件使用、无复用预期的简单 `ref` + 函数,直接写在 `<script setup>` 里。

---

## Composable Patterns

### 参数与返回值

参数超过 2 个时用单一 options 对象 + 接口;数据类型用泛型;返回一个包含 refs 与方法的普通对象(不返回 `reactive` 包裹的整体)。

```ts
// frontend/src/composables/useTableLoader.ts
interface TableLoaderOptions<T, P> {
  fetchFn: (page: number, pageSize: number, params: P, options?: FetchOptions) => Promise<BasePaginationResponse<T>>
  initialParams?: P
  pageSize?: number
  debounceMs?: number
}

export function useTableLoader<T, P extends Record<string, any>>(options: TableLoaderOptions<T, P>) {
  // ...
  return { items, loading, params, pagination, load, reload, debouncedReload, handlePageChange, handlePageSizeChange }
}
```

### 状态隔离(默认)

状态在工厂函数内部创建(`ref` / `reactive`),每个调用方独立实例。这是默认模式。

### 单例模式(例外)

确需全局共享的 composable 状态,用**惰性单例访问器**封装,并提供测试重置函数;不要把 `ref` 直接放在模块顶层裸导出。

```ts
// frontend/src/composables/useNavigationLoading.ts
let navigationLoadingInstance: ReturnType<typeof useNavigationLoading> | null = null

export function useNavigationLoadingState() {
  if (!navigationLoadingInstance) {
    navigationLoadingInstance = useNavigationLoading()
  }
  return navigationLoadingInstance
}

export function _resetNavigationLoadingInstance(): void { /* 测试用 */ }
```

### 生命周期清理

创建了定时器、AbortController、事件监听的 composable 必须在 `onUnmounted` / `onBeforeUnmount` 中清理。可能在组件 setup 之外被调用的 composable,注册钩子前先用 `getCurrentInstance()` 判空:

```ts
// frontend/src/composables/useKeyedDebouncedSearch.ts
if (getCurrentInstance()) {
  onUnmounted(() => {
    clearAll()
  })
}
```

### 优先使用 @vueuse/core

项目已依赖 `@vueuse/core`(^10.7.0)。防抖、节流等通用能力先查 vueuse,不要手写。例:`useTableLoader` 用 `useDebounceFn` 实现搜索防抖。

---

## Data Fetching

composable 中的请求统一调用 `frontend/src/api/` 下的 API 模块(如 `adminAPI`),不直接用 axios/fetch。

### 请求取消与竞态保护

列表/搜索类请求必须支持取消:新请求发出前 abort 旧请求,通过 `FetchOptions.signal` 传递;abort 错误静默忽略,不当作失败。

```ts
// frontend/src/composables/useTableLoader.ts
if (abortController) {
  abortController.abort()
}
const currentController = new AbortController()
abortController = currentController
// ...
const isAbortError = (error: any) => {
  return error?.name === 'AbortError' || error?.code === 'ERR_CANCELED' || error?.name === 'CanceledError'
}
```

多 key 并发场景(如多输入框搜索)额外用版本号丢弃过期响应,见 `useKeyedDebouncedSearch.ts` 的 `versions` Map。

### 错误处理与通知

- 用户可见的成功/失败提示统一走 `useAppStore().showSuccess / showError`(`frontend/src/stores/app.ts`)。
- API 错误文案用 `frontend/src/utils/apiError.ts` 的 `extractApiErrorMessage` / `extractI18nErrorMessage` 提取,兜底文案走 i18n(参考 `useGrokOAuth.ts`)。
- 需要组件局部处理的错误(如表单校验)在通知后继续 `throw`(参考 `useForm.ts`)。

### i18n 获取方式

- 组件 setup 上下文中调用的 composable:`const { t } = useI18n()`(`useGrokOAuth.ts`)。
- 可能在 setup 外使用的:模块级 `import { i18n } from '@/i18n'` 后取 `i18n.global.t`(`useClipboard.ts`)。

---

## localStorage Persistence

读写 localStorage 一律 `try/catch` 包裹并在 catch 中降级(`console.warn` 或忽略),读取值必须校验后再用;参考 `usePersistedPageSize.ts`、`useAutoRefresh.ts` 的 `loadFromStorage` / `saveToStorage`。

---

## Testing

- 每个含逻辑分支的 composable 应有对应 `__tests__/useXxx.spec.ts`;纯粘合(只转发 store/API)的可不测。
- 定时器逻辑用 `vi.useFakeTimers()`;`@vueuse/core` 与 `vue` 的生命周期钩子按需 `vi.mock`(参考 `__tests__/useTableLoader.spec.ts` 对 `useDebounceFn` 与 `onUnmounted` 的 mock)。
- 单例 composable 必须导出重置函数供测试隔离(`_resetNavigationLoadingInstance`)。

---

## Forbidden Patterns

1. **禁止模块顶层裸导出响应式状态**(`export const loading = ref(false)`)。全局状态用 Pinia store 或本文的惰性单例模式。
2. **禁止在 composables/ 之外新建 composable**:view/component 内可写私有的 setup 逻辑,但凡以 `use` 命名、预期复用的函数必须放 `frontend/src/composables/`。
3. **禁止创建定时器/监听/请求而不清理**:必须 `onUnmounted` / `onBeforeUnmount` 清理,或经 `getCurrentInstance()` 判空后降级为手动 `clearAll`。
4. **禁止在 composable 内直接调用 axios/fetch**:必须经 `@/api/` 模块。
5. **禁止列表/搜索请求不带 AbortSignal**:快速翻页、连续输入会产生竞态。
6. **禁止解构 `reactive` 对象后使用**(丢失响应性):`useTableLoader` 返回的 `params` / `pagination` 必须整体使用。
7. **禁止手写 vueuse 已有的通用能力**(防抖、节流等)。
8. **禁止在异步回调中首次调用 `useI18n()` / `useAppStore()` 等依赖注入型 API**:必须在 composable 函数体同步段获取,回调中引用闭包变量。
9. **禁止 default export**,统一命名导出。
