import { useState } from 'react'
import { Web3Provider, useWeb3 } from './lib/web3-context'
import Header from './components/layout/Header'
import TabNavigation from './components/layout/TabNavigation'
import OverviewTab from './components/overview/OverviewTab'
import CreateTokenTab from './components/create/CreateTokenTab'
import RegistryTab from './components/registry/RegistryTab'
import InspectorTab from './components/inspector/InspectorTab'
import AdminTab from './components/admin/AdminTab'
import PeripheralsTab from './components/peripherals/PeripheralsTab'
import './App.css'

const TYPE_STYLES: Record<string, string> = {
  ok:     'bg-ok text-bg',
  warn:   'bg-warn text-bg',
  danger: 'bg-danger text-bg',
}

function ToastContainer() {
  const { toasts, dismissToast } = useWeb3()
  if (toasts.length === 0) return null
  return (
    <div className="fixed bottom-4 right-4 z-50 flex flex-col gap-2 max-w-sm">
      {toasts.map(t => (
        <div
          key={t.id}
          className={`flex items-start gap-2 px-4 py-3 rounded shadow-lg text-sm font-medium cursor-pointer ${TYPE_STYLES[t.type]}`}
          onClick={() => dismissToast(t.id)}
        >
          <span className="flex-1">{t.message}</span>
          <span className="opacity-70 text-xs leading-5">✕</span>
        </div>
      ))}
    </div>
  )
}

function AppContent() {
  const [activeTab, setActiveTab] = useState('overview')

  return (
    <div className="min-h-screen bg-bg text-text font-system">
      <Header />

      <div className="shell">
        <TabNavigation activeTab={activeTab} onTabChange={setActiveTab} />

        {activeTab === 'overview' && <OverviewTab />}
        {activeTab === 'create' && <CreateTokenTab />}
        {activeTab === 'registry' && <RegistryTab />}
        {activeTab === 'inspector' && <InspectorTab />}
        {activeTab === 'admin' && <AdminTab />}
        {activeTab === 'peripherals' && <PeripheralsTab />}
      </div>

      <ToastContainer />
    </div>
  )
}

export default function App() {
  return (
    <Web3Provider>
      <AppContent />
    </Web3Provider>
  )
}
