import { useState } from 'react'
import { Web3Provider, useWeb3 } from './lib/web3-context'
import Header from './components/layout/Header'
import Sidebar from './components/layout/TabNavigation'
import OverviewTab from './components/overview/OverviewTab'
import CreateTokenTab from './components/create/CreateTokenTab'
import RegistryTab from './components/registry/RegistryTab'
import InspectorTab from './components/inspector/InspectorTab'
import AdminTab from './components/admin/AdminTab'
import PeripheralsTab from './components/peripherals/PeripheralsTab'
import AggregatorTab from './components/aggregator/AggregatorTab'
import MetaTxTab from './components/metatx/MetaTxTab'
import './App.css'

const TOAST_STYLES: Record<string, string> = {
  ok:     'bg-ok/10 text-ok border border-ok/20',
  warn:   'bg-warn/10 text-warn border border-warn/20',
  danger: 'bg-danger/10 text-danger border border-danger/20',
}

const TAB_LABELS: Record<string, string> = {
  overview:    'Overview',
  create:      'Create Token',
  registry:    'Registry',
  inspector:   'Inspector',
  admin:       'Admin',
  peripherals: 'Peripherals',
  aggregator:  'Aggregator',
  metatx:      'MetaTx',
}

function ToastContainer() {
  const { toasts, dismissToast } = useWeb3()
  if (!toasts.length) return null
  return (
    <div className="fixed bottom-4 right-4 z-50 flex flex-col gap-1.5 w-72 pointer-events-none">
      {toasts.map(t => (
        <div
          key={t.id}
          className={`flex items-start gap-2 px-3 py-2 rounded-md text-xs font-medium cursor-pointer pointer-events-auto backdrop-blur-sm ${TOAST_STYLES[t.type]}`}
          onClick={() => dismissToast(t.id)}
        >
          <span className="flex-1">{t.message}</span>
          <span className="opacity-40 leading-4 hover:opacity-80">✕</span>
        </div>
      ))}
    </div>
  )
}

function AppContent() {
  const [activeTab, setActiveTab] = useState('overview')
  const [sidebarOpen, setSidebarOpen] = useState(false)

  return (
    <div className="flex h-screen bg-bg text-text font-sans overflow-hidden">
      <Sidebar
        activeTab={activeTab}
        onTabChange={(tab) => { setActiveTab(tab); setSidebarOpen(false) }}
        isOpen={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
      />

      {sidebarOpen && (
        <div
          className="fixed inset-0 bg-black/50 z-20 md:hidden"
          onClick={() => setSidebarOpen(false)}
        />
      )}

      <div className="flex flex-col flex-1 min-w-0 overflow-hidden">
        <Header
          pageTitle={TAB_LABELS[activeTab] ?? activeTab}
          onMenuToggle={() => setSidebarOpen(s => !s)}
        />

        <main className="flex-1 overflow-y-auto">
          <div className="max-w-4xl mx-auto px-4 py-4">
            {activeTab === 'overview'    && <OverviewTab />}
            {activeTab === 'create'      && <CreateTokenTab />}
            {activeTab === 'registry'    && <RegistryTab />}
            {activeTab === 'inspector'   && <InspectorTab />}
            {activeTab === 'admin'       && <AdminTab />}
            {activeTab === 'peripherals' && <PeripheralsTab />}
            {activeTab === 'aggregator'  && <AggregatorTab />}
            {activeTab === 'metatx'      && <MetaTxTab />}
          </div>
        </main>
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
