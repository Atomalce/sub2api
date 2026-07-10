# Component Guidelines

> sub2api 前端 Vue 组件规范。内部项目精简版。

---

## Overview

- 技术栈:Vue 3 `<script setup lang="ts">` 组合式 API + TypeScript + Tailwind CSS + vue-i18n,全部组件位于 `frontend/src/`。
- 全仓库约 180 个 `.vue` 组件,**统一使用 `<script setup>`,禁止 Options API**(`export default {}` 写法零存在)。
- 单文件组件顺序:`<template>` 在前,`<script setup lang="ts">` 在后,`<style>` 仅在确有必要时追加(全仓库仅约 30 个组件有 `<style>`)。
- 组合式函数(composables)规范见同目录 `hook-guidelines.md`,状态管理见 `state-management.md`。

---

## Directory & Naming

```
frontend/src/
├── components/
│   ├── common/     # 公共基础组件(BaseDialog、DataTable、Pagination 等),经 index.ts 桶导出
│   ├── layout/     # 布局(AppLayout、AppHeader、AppSidebar、TablePageLayout)
│   ├── icons/      # Icon.vue 统一 SVG 图标组件(按 name 查表渲染 path)
│   ├── charts/     # 图表组件(chart.js)
│   ├── admin/ user/ account/ auth/ keys/ channels/ payment/  # 按业务域分目录
├── views/          # 路由页面,按 admin/ user/ auth/ public/ 分区
└── composables/    # useXxx.ts 组合式函数
```

- 组件文件名 **PascalCase**:`UserEditModal.vue`、`StatusBadge.vue`。
- 页面组件以 `View` 结尾:`views/admin/UsersView.vue`、`views/user/KeysView.vue`。
- 弹窗组件以 `Modal` 或 `Dialog` 结尾:`admin/user/UserBalanceModal.vue`、`common/ConfirmDialog.vue`。
- 单元测试放在同级 `__tests__/` 目录,命名 `Xxx.spec.ts`(Vitest),如 `components/common/__tests__/DataTable.spec.ts`。
- 公共组件新增后须在 `components/common/index.ts` 中导出;使用方可 `import { DataTable, Pagination } from '@/components/common'` 或直接按路径导入。
- 路径别名统一用 `@/`(指向 `frontend/src`),禁止长相对路径 `../../..`。

---

## Props Conventions

统一使用**类型声明式** `defineProps<Props>()`,需要默认值时配 `withDefaults`。摘自 `frontend/src/components/common/Pagination.vue`:

```ts
interface Props {
  total: number
  page: number
  pageSize: number
  pageSizeOptions?: number[]
  showPageSizeSelector?: boolean
  showJump?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  pageSizeOptions: () => getConfiguredTablePageSizeOptions(),
  showPageSizeSelector: true,
  showJump: false
})
```

- 简单组件可内联泛型:`defineProps<{ status: string; label: string }>()`(见 `common/StatusBadge.vue`)。
- 可选 props 用 `?:` 标注;数组/对象默认值必须用工厂函数。
- 模板中传 props 用 kebab-case:`confirm-text="Delete"`、`:action-to="{ name: 'xxx' }"`。

---

## Events Conventions

- 优先使用带类型签名的 `defineEmits`(公共组件必须),业务弹窗允许简写数组形式:

```ts
// frontend/src/components/common/Input.vue —— 公共组件,带类型
const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void
  (e: 'change', value: string): void
  (e: 'blur', event: FocusEvent): void
}>()

// frontend/src/components/admin/user/UserEditModal.vue —— 业务弹窗,简写
const emit = defineEmits(['close', 'success'])
```

- **v-model 约定**:表单类公共组件用 `modelValue` prop + `update:modelValue` 事件(见 `common/Input.vue`、`common/Select.vue`);分页组件用多 v-model:`update:page` / `update:pageSize`。
- **弹窗约定**(全项目统一):父组件传 `show: boolean` 控制显隐,子组件 emit `close`(关闭)与 `success`(操作成功,父组件借此刷新列表)。不使用内部 `visible` 状态自管理。
- 需要暴露方法时用 `defineExpose`,只暴露最小集合(如 `Input.vue` 暴露 `focus`/`select`)。

---

## Common Components

新写页面前先查 `frontend/src/components/common/`(附 README.md 文档),已有能力禁止重复造:

| 组件 | 用途 |
|---|---|
| `BaseDialog.vue` | 所有弹窗的基座(Teleport + 焦点管理 + ARIA),业务 Modal 必须基于它组合 |
| `ConfirmDialog.vue` | 确认框,`danger` prop 切红色样式 |
| `DataTable.vue` | 通用表格:排序、loading 骨架、`#cell-{key}` 自定义单元格插槽 |
| `Pagination.vue` | 分页 + 每页条数 + 跳页 |
| `Toast.vue` | 全局通知,已挂载,业务代码通过 `useAppStore().showSuccess/showError(t('...'))` 触发 |
| `Icon.vue` (`components/icons/`) | 统一 SVG 图标,`<Icon name="trash" size="md" />`,新图标加进其内部 icons 表 |
| `EmptyState.vue` / `LoadingSpinner.vue` / `Skeleton.vue` | 空态 / 加载态 |
| `Input.vue` / `Select.vue` / `TextArea.vue` / `Toggle.vue` / `SearchInput.vue` | 表单控件 |
| `TablePageLayout.vue` (`components/layout/`) | 列表页脚手架,admin 列表页(如 `views/admin/AccountsView.vue`)统一使用 |

业务弹窗标准形态,摘自 `frontend/src/components/admin/user/UserBalanceModal.vue`:

```vue
<BaseDialog :show="show" :title="t('admin.users.deposit')" width="narrow" @close="$emit('close')">
  <form id="balance-form" @submit.prevent="handleBalanceSubmit" class="space-y-5">...</form>
  <template #footer>
    <button @click="$emit('close')" class="btn btn-secondary">{{ t('common.cancel') }}</button>
    <button type="submit" form="balance-form" :disabled="submitting" class="btn btn-primary">
      {{ submitting ? t('common.saving') : t('common.confirm') }}
    </button>
  </template>
</BaseDialog>
```

---

## Styling (Tailwind & Theme)

- **Tailwind utility-first**,样式直接写在 template 的 class 上;不写 CSS Modules,不引入 CSS-in-JS。
- 暗色模式为 `darkMode: 'class'`(`frontend/tailwind.config.js`)。**每一处颜色类都必须成对写 `dark:` 变体**,如 `text-gray-700 dark:text-gray-300`、`bg-white dark:bg-dark-800`。
- 主题色定义在 `tailwind.config.js`:`primary`(teal 青色系)、`accent` 与 `dark`(slate 深色背景)。颜色一律引用这些 token,禁止裸写十六进制色值。
- 跨组件复用的样式类集中在 `frontend/src/style.css` 的 `@layer components`,直接使用而非重写:
  - 按钮:`.btn` + `.btn-primary/-secondary/-ghost/-danger/-success` + 尺寸 `.btn-sm/-md/-lg/-icon`
  - 表单:`.input` `.input-label` `.input-error` `.input-hint`
  - 容器:`.card` `.card-header/-body/-footer` `.badge` `.badge-primary/...` `.modal-overlay/-content/-header/-body/-footer`
- 组件内 `<style scoped>` 仅用于 Tailwind 难以表达的场景(第三方挂件、复杂动画),是例外不是常规,新增前先考虑 utility 类或 `style.css`。

---

## i18n

- 所有用户可见文案必须走 vue-i18n:`const { t } = useI18n()`,模板内 `{{ t('admin.users.deposit') }}`。
- 语言包在 `frontend/src/i18n/locales/{zh,en}/`,新增 key 必须中英双份。
- key 按 `域.页面.语义` 组织,通用文案放 `common.*`(如 `common.cancel`、`common.saving`)。

---

## Forbidden Patterns

- **禁止** Options API(`export default { data() ... }`)——全仓库统一 `<script setup lang="ts">`。
- **禁止** 运行时 props 声明(`defineProps({ total: Number })`)——必须用 TS 类型声明式。
- **禁止** 模板中硬编码用户可见文案(中文或英文)——一律 `t('...')`。
- **禁止** 颜色类只写亮色不写 `dark:` 变体;或绕过主题 token 裸写 `#0d9488`、`bg-[#xxx]`。
- **禁止** 不经 `BaseDialog` 自造弹窗(自己写 overlay/Teleport/Esc 处理)。
- **禁止** 用 `window.alert/confirm` 或自造通知——用 `appStore.showSuccess/showError` 与 `ConfirmDialog`。
- **禁止** 弹窗组件内部自管理显隐——必须遵守 `show` prop + `close`/`success` 事件约定。
- **禁止** 重复实现 `common/` 已有组件(表格、分页、空态、表单控件、图标)。
- **禁止** 在组件里直接写 `fetch`/`axios`——API 调用走 `frontend/src/api/` 封装(如 `adminAPI.users.updateBalance(...)`)。
