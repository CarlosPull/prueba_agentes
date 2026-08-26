# Patrones de Referencia Vue 3

## Componente Estándar (`<script setup lang="ts">`)

```vue
<script setup lang="ts">
import { ref, onMounted } from 'vue'

const loading = ref(true)
const data = ref<any>(null)

onMounted(async () => {
  // Cargar datos
})
</script>

<template>
  <div class="container">
    <slot />
  </div>
</template>
```
