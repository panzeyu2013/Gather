import React, { Component, type ReactNode } from 'react'
import { useLocation } from 'react-router-dom'
import { translateError } from '../../utils/errors'
import { t } from '../../locales'
import styles from './ErrorBoundary.module.css'

interface Props {
  children: ReactNode
  fallback?: ReactNode
}

interface State {
  hasError: boolean
  error: Error | null
}

function RouteAwareErrorBoundary(props: Props) {
  const location = useLocation()
  return <ErrorBoundary resetKey={location.pathname} {...props} />
}

export default class ErrorBoundary extends Component<Props & { resetKey?: string }, State> {
  state: State = { hasError: false, error: null }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error }
  }

  componentDidUpdate(prevProps: Props & { resetKey?: string }) {
    if (this.state.hasError && this.props.resetKey !== prevProps.resetKey) {
      this.handleRetry()
    }
  }

  handleRetry = () => {
    this.setState({ hasError: false, error: null })
  }

  render() {
    if (this.state.hasError) {
      if (this.props.fallback) return this.props.fallback
      return (
        <div className={styles.container} role="alert">
          <div className={styles.icon} aria-hidden="true">!</div>
          <h2 className={styles.title}>{t('errorBoundary.title')}</h2>
          <p className={styles.message}>
            {this.state.error ? translateError(this.state.error) : t('errorBoundary.unknown')}
          </p>
          <button
            type="button"
            onClick={this.handleRetry}
            className={styles.retryButton}
          >
            {t('errorBoundary.retry')}
          </button>
        </div>
      )
    }
    return this.props.children
  }
}

export { RouteAwareErrorBoundary }
