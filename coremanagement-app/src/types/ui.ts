// UI-related types
export type TabId = 'overview' | 'create' | 'registry' | 'inspector' | 'admin' | 'peripherals'

export interface Toast {
  id: string
  message: string
  type: 'ok' | 'danger' | 'warn'
  duration?: number
}

export interface LoadingState {
  isLoading: boolean
  error?: string
}
