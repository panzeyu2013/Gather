import React, { useState } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { historyApi } from '../../api/history'
import type { OperationLogEntry } from '@gather/shared'
import styles from './History.module.css'

function OperationItem({ entry, onUndo, canUndo }: { entry: OperationLogEntry; onUndo: () => void; canUndo: boolean }) {
  const [showDiff, setShowDiff] = useState(false)

  const typeLabel: Record<string, string> = {
    face_bind: 'Face Bind',
    face_unbind: 'Face Unbind',
    face_merge: 'Face Merge',
    culling_batch: 'Culling Batch',
    dup_resolve: 'Duplicate Resolve',
    template_apply: 'Template Apply',
  }

  const undoLabel = entry.isUndo === 0 ? '' : entry.isUndo === 1 ? '(Undone)' : '(Redone)'

  return (
    <div className={styles.item}>
      <div className={styles.itemHeader}>
        <span className={styles.itemType}>{typeLabel[entry.operationType] ?? entry.operationType}</span>
        <span className={`${styles.itemUndo} ${entry.isUndo > 0 ? styles.undone : styles.active}`}>
          {undoLabel || 'Active'}
        </span>
        <span className={styles.itemTime}>{new Date(entry.createdAt).toLocaleString()}</span>
      </div>
      <div className={styles.itemDesc}>{entry.description}</div>

      <div className={styles.itemActions}>
        <button className={styles.btnSm} onClick={() => setShowDiff(!showDiff)}>
          {showDiff ? 'Hide Diff' : 'Show Diff'}
        </button>
        {canUndo && entry.isUndo === 0 && (
          <button className={`${styles.btnSm} ${styles.btnUndo}`} onClick={onUndo}>
            Undo
          </button>
        )}
      </div>

      {showDiff && (
        <div className={styles.diff}>
          <div className={styles.diffCol}>
            <div className={styles.diffTitle}>Before</div>
            <pre className={styles.diffContent}>{entry.snapshotBefore ? JSON.stringify(entry.snapshotBefore, null, 2) : '(empty)'}</pre>
          </div>
          <div className={styles.diffCol}>
            <div className={styles.diffTitle}>After</div>
            <pre className={styles.diffContent}>{entry.snapshotAfter ? JSON.stringify(entry.snapshotAfter, null, 2) : '(empty)'}</pre>
          </div>
        </div>
      )}
    </div>
  )
}

export default function History() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const queryClient = useQueryClient()
  const [confirmUndo, setConfirmUndo] = useState<number | null>(null)

  const { data: entries, isLoading, isError } = useQuery({
    queryKey: ['history', sessionId],
    queryFn: () => historyApi.list(sessionId!, 50, 0),
    enabled: !!sessionId,
  })

  const { data: undoStatus } = useQuery({
    queryKey: ['history-can-undo', sessionId],
    queryFn: () => historyApi.canUndo(sessionId!),
    enabled: !!sessionId,
  })

  const { data: redoStatus } = useQuery({
    queryKey: ['history-can-redo', sessionId],
    queryFn: () => historyApi.canRedo(sessionId!),
    enabled: !!sessionId,
  })

  const undoMutation = useMutation({
    mutationFn: (operationId?: number) => historyApi.undo(sessionId!, operationId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['history', sessionId] })
      queryClient.invalidateQueries({ queryKey: ['history-can-undo', sessionId] })
      queryClient.invalidateQueries({ queryKey: ['history-can-redo', sessionId] })
      setConfirmUndo(null)
    },
  })

  const redoMutation = useMutation({
    mutationFn: () => historyApi.redo(sessionId!),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['history', sessionId] })
      queryClient.invalidateQueries({ queryKey: ['history-can-undo', sessionId] })
      queryClient.invalidateQueries({ queryKey: ['history-can-redo', sessionId] })
    },
  })

  const handleUndo = (operationId: number) => {
    setConfirmUndo(operationId)
  }

  const confirmUndoAction = () => {
    if (confirmUndo !== null) {
      undoMutation.mutate(confirmUndo)
    }
  }

  const cancelUndoAction = () => {
    setConfirmUndo(null)
  }

  if (!sessionId) {
    return <div className={styles.page}><div className={styles.empty}>No session selected</div></div>
  }

  if (isLoading) {
    return <div className={styles.page}><div className={styles.empty}>Loading...</div></div>
  }

  if (isError) {
    return <div className={styles.page}><div className={styles.empty}>Failed to load history</div></div>
  }

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>Operation History</h2>

      <div className={styles.statusBar}>
        <span className={undoStatus?.canUndo ? styles.statusActive : styles.statusInactive}>
          Undo: {undoStatus?.canUndo ? undoStatus.operation?.operationType ?? 'Available' : 'None'}
        </span>
        <span className={redoStatus?.canRedo ? styles.statusActive : styles.statusInactive}>
          Redo: {redoStatus?.canRedo ? redoStatus.operation?.operationType ?? 'Available' : 'None'}
        </span>
        {undoStatus?.canUndo && (
          <button className={`${styles.btn} ${styles.btnUndo}`} onClick={() => handleUndo(undoStatus.operation!.id)}>
            Undo Latest
          </button>
        )}
        {redoStatus?.canRedo && (
          <button className={styles.btn} onClick={() => redoMutation.mutate()} disabled={redoMutation.isPending}>
            {redoMutation.isPending ? 'Redoing...' : 'Redo'}
          </button>
        )}
      </div>

      {entries && entries.length === 0 ? (
        <div className={styles.empty}>No operations recorded yet</div>
      ) : (
        <div className={styles.list}>
          {(entries ?? []).map((entry) => (
            <OperationItem
              key={entry.id}
              entry={entry}
              canUndo={entry.isUndo === 0}
              onUndo={() => handleUndo(entry.id)}
            />
          ))}
        </div>
      )}

      {confirmUndo !== null && (
        <div className={styles.dialog} onClick={cancelUndoAction}>
          <div className={styles.dialogContent} onClick={(e) => e.stopPropagation()}>
            <div className={styles.dialogTitle}>Confirm Undo</div>
            <div className={styles.dialogBody}>
              Are you sure you want to undo this operation? This action cannot be undone.
            </div>
            <div className={styles.dialogActions}>
              <button className={styles.btn} onClick={cancelUndoAction}>Cancel</button>
              <button
                className={`${styles.btn} ${styles.btnUndo}`}
                onClick={confirmUndoAction}
                disabled={undoMutation.isPending}
              >
                {undoMutation.isPending ? 'Undoing...' : 'Confirm Undo'}
              </button>
            </div>
            {undoMutation.isError && (
              <div className={styles.error}>
                {undoMutation.error instanceof Error ? undoMutation.error.message : 'Undo failed'}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
