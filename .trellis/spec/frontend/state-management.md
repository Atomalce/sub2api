# State Management

> sub2api 前端状态管理规范。内部项目精简版。

---

## Overview

- 全局状态方案:**Pinia 2**(`pinia: ^2.1.7`),全部使用 **setup store 语法**(Composition API 风格),禁止 options store(`state/getters/actions` 对象式)。
- 所有 store 位于 `frontend/src/stores/`,并在 `frontend/src/stores/index.ts` 统一 re-export。
- **没有** vue-query / SWR 类库:服务端状态要么由 store 手写缓存,要么由组件配合 composable(如 `useTableLoader`)在页面内管理。见「Server State」。
- 持久化全部手动写 `localStorage`,**不使用** pinia 持久化插件。
- `createPinia()` 在 `frontend/src/main.ts` 中安装;`useAppStore().initFromInjectedConfig()` 必须在 router/i18n 安装前、app mount 前同步调用(消除首屏配置闪烁)。

现有 store(8 个):`auth` `app` `adminSettings` `subscriptions` `onboarding` `announcements` `payment` `adminCompliance`。

---

## Store Organization

- 一个领域一个文件:`frontend/src/stores/<domain>.ts`,导出 `use<Domain>Store`,`defineStore` 的 id 用 camelCase 且与文件名一致(如 `defineStore('adminSettings', ...)`)。
- 新 store 必须加入 `frontend/src/stores/index.ts` 的导出列表。
- store 内部按分段注释组织(参照 `frontend/src/stores/auth.ts`):

```ts
// frontend/src/stores/auth.ts(骨架)
export const useAuthStore = defineStore('auth', () => {
  // ==================== State ====================
  const user = ref<User | null>(null)
  let refreshIntervalId: ReturnType<typeof setInterval> | null = null // 非响应式内部变量用 let

  // ==================== Computed ====================
  const isAuthenticated = computed(() => !!token.value && !!user.value)

  // ==================== Actions ====================
  async function login(credentials: LoginRequest): Promise<LoginResponse> { /* ... */ }

  // ==================== Return Store API ====================
  return { user, isAuthenticated, login /* 只暴露需要的成员 */ }
})
```

细则:

- 定时器 id、in-flight Promise、代数计数器等**非响应式内部变量**用闭包/模块级 `let`,不进 `ref`、不出现在 return 中(例:`subscriptions.ts` 的 `activePromise`、`auth.ts` 的 `refreshIntervalId`)。
- 只读暴露:不希望外部修改的状态用 `readonly()` 包装后 return(例:`auth.ts` 中 `runMode: readonly(runMode)`)。
- 第三方类实例用 `shallowRef` + `markRaw`,避免深层响应式代理破坏其内部行为(例:`onboarding.ts` 中 driver.js 的 `Driver` 实例)。

---

## State Categories

| 类别 | 放哪里 | 例子 |
|------|--------|------|
| 组件本地 UI 状态 | 组件内 `ref`/`reactive` | 弹窗开关、表单输入 |
| 全局 UI 状态 | `app` store | sidebar 折叠、toast、全局 loading |
| 会话/身份状态 | `auth` store(唯一写入方) | token、user、2FA 待处理会话 |
| 跨页面共享的服务端数据 | 领域 store + 手写缓存 | 订阅列表、公开设置、版本信息 |
| 页面私有的服务端列表数据 | 组件内 + `useTableLoader` | 各管理页的分页表格 |
| 跨组件回调/实例桥接 | store 存回调引用 | `onboarding.ts` 的 tour 控制方法 |

**提升为全局 store 的标准**:数据被 2 个以上不相关组件(跨路由)消费,或需要跨路由存活/轮询。仅单页面用的数据一律留在组件内。

---

## Server State

无服务端状态库,按两条路径处理:

**路径 A — 全局共享数据进 store,手写缓存**。标准形态见 `frontend/src/stores/subscriptions.ts`:

```ts
// frontend/src/stores/subscriptions.ts(节选)
const CACHE_TTL_MS = 60_000
let requestGeneration = 0 // 代数计数器,防止过期响应覆盖新数据

async function fetchActiveSubscriptions(force = false): Promise<UserSubscription[]> {
  const now = Date.now()
  // 1. 缓存命中直接返回
  if (!force && loaded.value && lastFetchedAt.value && now - lastFetchedAt.value < CACHE_TTL_MS) {
    return activeSubscriptions.value
  }
  // 2. in-flight 去重:并发调用共享同一个 Promise
  if (activePromise && !force) {
    return activePromise
  }
  const currentGeneration = ++requestGeneration
  loading.value = true
  const requestPromise = subscriptionsAPI.getActiveSubscriptions()
    .then((data) => {
      if (currentGeneration === requestGeneration) { /* 只有最新一代请求可写入 state */ }
      return data
    })
    .finally(() => {
      if (activePromise === requestPromise) { loading.value = false; activePromise = null }
    })
  activePromise = requestPromise
  return activePromise
}
```

fetch 型 action 的约定(`subscriptions.ts` / `adminSettings.ts` / `app.ts` 的 `fetchVersion`、`fetchPublicSettings` 均遵循):

- 签名统一为 `fetch(force = false)`;`loaded` + `loading` 两个 ref 标志必备。
- 必须做 in-flight 去重(共享 Promise);写回 state 前用代数计数器或 `activePromise === requestPromise` 判等,防止旧响应覆盖新数据。
- 提供失效手段:`invalidateCache()` / `clear()`(登出等场景调用)。
- fetch 失败**不回滚已有缓存值**,只 `console.error`,避免瞬时故障导致 UI 翻转(见 `adminSettings.ts` 的注释)。
- 轮询放 store 内(`startPolling`/`stopPolling`),定时器 id 用闭包 `let`,`clear()` 时必须停表。

**路径 B — 页面私有列表数据留在组件**,统一走 `frontend/src/composables/useTableLoader.ts`:内部用 `ref`/`reactive` 管理 items/分页/筛选,自带搜索防抖与 `AbortController` 请求取消,`onUnmounted` 时 abort。这类数据**禁止**放进全局 store。

---

## Persistence

- 手动 `localStorage`,读写必须收敛在对应 store 内:
  - `auth` store:`auth_token` / `auth_user` / `refresh_token` / `token_expires_at` / `pending_auth_session`。写 token 必须 store 状态与 localStorage 同步写(`frontend/src/api/client.ts` 的 axios 拦截器直接读 `localStorage.getItem('auth_token')` 注入请求头,两者不同步会导致带错 token)。
  - `adminSettings` store:`*_cached` 键(如 `ops_monitoring_enabled_cached`)缓存布尔/字符串配置,首屏先读缓存值再异步刷新,减少闪烁;localStorage 读写包 try/catch 静默失败。
- `app` store 的 UI 状态(sidebar、toast)不持久化,刷新即重置。
- 已有例外(不要扩散):`api/client.ts` 拦截器在 401 刷新流程中直接读写 `auth_token`/`refresh_token`;除此之外任何组件/composable 不得直接操作这些键。

---

## Using Stores

- 组件中直接持有 store 实例访问属性(`authStore.user`、`appStore.loading`),这是主流写法;需要解构时**必须** `storeToRefs`(现存示例:`frontend/src/components/common/AnnouncementBell.vue` 的 `const { announcements, loading } = storeToRefs(announcementStore)`)。
- 路由守卫中必须在守卫回调**内部**调用 `useAuthStore()`(见 `frontend/src/router/index.ts` `beforeEach` 内),不得在模块顶层调用——那时 pinia 尚未安装。
- 应用启动:`main.ts` 中先 `app.use(pinia)`,再 `appStore.initFromInjectedConfig()`;`authStore.checkAuth()` 负责从 localStorage 恢复会话并启动 token 自动刷新。

---

## Testing

- store 测试放 `frontend/src/stores/__tests__/*.spec.ts`(Vitest)。
- `beforeEach` 中 `setActivePinia(createPinia())` 重置状态;API 层用 `vi.mock('@/api/...')` 模拟(参照 `frontend/src/stores/__tests__/subscriptions.spec.ts`)。
- 涉及缓存 TTL / 轮询的测试用 `vi.useFakeTimers()`。

---

## Forbidden Patterns

- **禁止** options store 语法(`defineStore('x', { state, getters, actions })`)——全项目统一 setup store。
- **禁止**直接解构 store 的响应式状态(`const { user } = useAuthStore()`)——丢失响应性;用实例属性访问或 `storeToRefs`。
- **禁止**在模块顶层(pinia 安装前)调用 `useXxxStore()`,包括 router 模块顶层。
- **禁止**在 store 之外读写 `auth_token` 等 auth 相关 localStorage 键(唯一既有例外:`api/client.ts` 拦截器)。
- **禁止**把页面私有的分页/表格数据放进全局 store——用 `useTableLoader` 留在组件内。
- **禁止** fetch 型 action 不做 in-flight 去重与代数判定就直接写 state——并发/慢响应会互相覆盖。
- **禁止**把第三方类实例放入深响应式 `ref`——用 `shallowRef` + `markRaw`。
- **禁止**引入 pinia 持久化插件或新的状态库(vuex、vue-query 等)——现有手写模式已覆盖需求,如需改变先改本规范。
