# Quality Guidelines

> 前端代码质量规范。内部项目精简版。

---

## Overview

前端位于 `frontend/`,技术栈 Vue 3(组合式 API,`<script setup>`)+ TypeScript + Vite + Pinia + vue-i18n,包管理 pnpm 9,测试 Vitest。质量门槛由三件事构成:ESLint、vue-tsc 类型检查、Vitest 关键用例,三者都在 CI 中强制执行(`.github/workflows/backend-ci.yml` 的 `frontend` job 执行 `make test-frontend`)。

相关规范:组合式函数见 [Composables Guidelines](./hook-guidelines.md),组件见 [Component Guidelines](./component-guidelines.md),类型见 [Type Safety](./type-safety.md)。

---

## Lint & Format

配置文件:`frontend/.eslintrc.cjs`(ESLint 8 传统配置,非 flat config)。规则集:`eslint:recommended` + `plugin:vue/vue3-essential` + `plugin:@typescript-eslint/recommended`。

```bash
pnpm lint         # eslint --fix,自动修复
pnpm lint:check   # 只检查不修复,CI 使用这条
```

项目已明确放宽的规则(见 `.eslintrc.cjs`),不要"顺手修复"它们:

- `@typescript-eslint/no-explicit-any: off` —— 允许 `any`,但新代码仍应优先写具体类型
- `@typescript-eslint/no-unused-vars: warn`,`_` 前缀的参数/变量豁免
- `vue/multi-word-component-names: off` —— 允许 `HomeView.vue` 这类单词命名

**没有 Prettier**,格式不由工具强制。跟随既有代码风格:2 空格缩进、单引号、无分号(参照 `frontend/src/api/client.ts`、`frontend/src/i18n/index.ts`)。

---

## Type Checking

```bash
pnpm typecheck    # vue-tsc --noEmit
pnpm build        # vue-tsc -b && vite build,构建前先过类型检查
```

`pnpm dev` 时 `vite-plugin-checker`(`vite.config.ts` 中 `checker({ vueTsc: true })`)会实时报类型错误,开发中就该修掉,不要留到 build 才发现。

---

## Pre-commit Checks

提交前在仓库根目录跑:

```bash
make test-frontend
```

等价于(见根目录 `Makefile`):

1. `pnpm --dir frontend run lint:check`
2. `pnpm --dir frontend run typecheck`
3. `make test-frontend-critical` —— 只跑 `FRONTEND_CRITICAL_VITEST` 列出的关键用例(支付、登录回调、Profile、Settings 等)

CI 跑的就是这条命令,本地过了 CI 才会过。改动涉及测试覆盖的模块时,额外跑完整测试:

```bash
pnpm test:run        # 全量 vitest
pnpm test:coverage   # 带覆盖率
```

---

## Testing Requirements

- 测试与被测代码同目录,放 `__tests__/` 下,命名 `*.spec.ts`(如 `src/composables/__tests__/useClipboard.spec.ts`)
- 环境:jsdom,全局 setup 在 `src/__tests__/setup.ts`(见 `vitest.config.ts`)
- `vitest.config.ts` 中 coverage thresholds 为 80%(statements/branches/functions/lines),`pnpm test:coverage` 时生效
- 改动关键路径(`Makefile` 中 `FRONTEND_CRITICAL_VITEST` 列表内的文件)必须保证对应 spec 通过;新增关键页面时把 spec 加进该列表
- 新增 composable 应带 spec,参照 `src/composables/__tests__/` 下既有用例

---

## i18n Workflow

文案存放在 `src/i18n/locales/{en,zh}/`,按领域拆模块:`common.ts`、`dashboard.ts`、`landing.ts`、`misc.ts`、`admin/`(下分 `accounts.ts`、`channels.ts`、`ops.ts`、`overview.ts`、`resources.ts`、`settings.ts`)。语言包按需懒加载(`src/i18n/index.ts` 的 `loadLocaleMessages`)。

添加文案的流程:

1. 选对领域模块,`en` 与 `zh` **同一次提交里成对添加**,key 路径完全一致
2. 组件中通过 `useI18n()` 取 `t()` 使用;插值写法如 `peakRateTooltip: '高峰倍率:{window}'`(`src/i18n/locales/zh/common.ts`)
3. 跑 i18n 守护测试:

```bash
pnpm exec vitest run src/i18n/__tests__/
```

注意:`locales/{en,zh}/index.ts` 用对象展开聚合各模块——

```ts
// src/i18n/locales/en/index.ts
export default {
  ...landing,
  ...common,
  ...dashboard,
  admin,
  ...misc,
}
```

展开模块之间的同名顶层 key 会**静默覆盖**。`src/i18n/__tests__/localesNoKeyCollision.spec.ts` 把该风险固化为显式失败:新增顶层 key 撞名会挂测试,新增 locale 模块时要把它补进这个 spec 的导入列表。

另:i18n 消息中避免依赖 HTML 渲染;`warnHtmlMessage: false` 只是为 driver.js 引导步骤的内部富文本开的口子(见 `src/i18n/index.ts` 注释),不是给业务文案用的。

---

## Forbidden Patterns

- **禁止在业务代码直接 `import axios`**。所有 HTTP 请求走 `src/api/client.ts` 导出的 `apiClient`(或各领域 API 模块,统一出口 `src/api/index.ts`)——token 附加、401 刷新排队、时区头、错误处理都在拦截器里。目前直接引 axios 的只有 `api/client.ts` 与 `api/setup.ts`,保持现状。
- **禁止未消毒的 `v-html`**。渲染用户/后台可配置内容前必须过 DOMPurify:Markdown 参照 `src/components/common/AnnouncementPopup.vue`(`marked.parse` 后 `DOMPurify.sanitize`),SVG 用 `src/utils/sanitize.ts` 的 `sanitizeSvg`。
- **禁止硬编码界面文案**。所有用户可见字符串走 vue-i18n,且 en/zh 成对补齐;只加一种语言等于线上另一语言显示裸 key。
- **禁止 Options API 与 `<template>` 里的复杂逻辑**。全仓库统一 `<script setup lang="ts">`(258/260 个 `.vue` 文件),Pinia store 统一 setup 风格 `defineStore('app', () => {...})`(见 `src/stores/app.ts`)。
- **禁止手改 `pnpm-lock.yaml` 与构建产物 `dist/`**。依赖版本需要钉死时用 `package.json` 的 `pnpm.overrides`(现有先例:`js-cookie`、`form-data`);CI 用 `pnpm install --frozen-lockfile`,lockfile 与 `package.json` 不一致会直接挂。
- **禁止为过 lint/类型检查而放宽全局配置**。`.eslintrc.cjs`、`tsconfig.json` 的改动需要单独说明理由,不允许夹在业务 PR 里顺手改。
- **禁止自造 toast/通知**。成功、失败提示统一走 `useAppStore()` 的 `showSuccess` / `showError`(`src/stores/app.ts`),参照 `src/composables/useClipboard.ts` 的用法。

---

## Code Review Checklist

- [ ] `make test-frontend` 本地通过(lint + typecheck + critical vitest)
- [ ] 新文案 en/zh 成对出现,`src/i18n/__tests__/` 全绿
- [ ] 网络请求走 `apiClient` / 领域 API 模块,无裸 axios
- [ ] `v-html` 有 DOMPurify 消毒
- [ ] 新组件为 `<script setup lang="ts">`,新 composable 位于 `src/composables/` 且命名 `useXxx`
- [ ] 涉及关键路径的改动,确认 `FRONTEND_CRITICAL_VITEST` 对应 spec 已更新
