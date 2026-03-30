import { useState } from 'react'
import { Web3Provider } from './lib/web3-context'
import Header from './components/layout/Header'
import TabNavigation from './components/layout/TabNavigation'
import OverviewTab from './components/overview/OverviewTab'
import CreateTokenTab from './components/create/CreateTokenTab'
import RegistryTab from './components/registry/RegistryTab'
import InspectorTab from './components/inspector/InspectorTab'
import AdminTab from './components/admin/AdminTab'
import PeripheralsTab from './components/peripherals/PeripheralsTab'
import './App.css'

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
