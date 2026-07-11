import React, { Component, type ReactNode } from 'react'

interface Props {
  children: ReactNode
  fallback?: ReactNode
}

interface State {
  hasError: boolean
  error: Error | null
}

export default class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false, error: null }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error }
  }

  handleRetry = () => {
    this.setState({ hasError: false, error: null })
  }

  render() {
    if (this.state.hasError) {
      if (this.props.fallback) return this.props.fallback
      return (
        <div style={{ padding: 32, textAlign: 'center' }}>
          <h2 style={{ color: '#ff6b6b', marginBottom: 12 }}>出了点问题</h2>
          <p style={{ color: '#999', marginBottom: 16, fontSize: 14 }}>
            {this.state.error?.message ?? '未知错误'}
          </p>
          <button
            onClick={this.handleRetry}
            style={{
              padding: '8px 24px',
              background: '#6c8cff',
              border: 'none',
              borderRadius: 6,
              color: '#fff',
              cursor: 'pointer',
              fontSize: 14,
            }}
          >
            重试
          </button>
        </div>
      )
    }
    return this.props.children
  }
}
