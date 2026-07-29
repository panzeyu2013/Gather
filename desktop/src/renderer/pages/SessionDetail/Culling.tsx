import React, { useState, useEffect, useCallback, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { cullingApi } from '../../api/culling'
import { imageApi } from '../../api/image'
import type { CullingGroup } from '@gather/shared'
import type { WritebackResult } from '@gather/shared'
import styles from './Culling.module.css'

function ViewerImage({ path, className }: { path: string; className?: string }) {
  return <img src={imageApi.previewUrl(path, 1920)} alt={path} className={className} />
}

function ThumbnailImg({ path, className }: { path: string; className?: string }) {
  return <img src={imageApi.thumbnailUrl(path, 160)} alt={path} className={className} />
}

function WritebackDialog({
  onClose,
  sessionId,
}: {
  onClose: () => void
  sessionId: string
}) {
  const [selected, setSelected] = useState<'rating' | 'color_label' | 'keyword'>('keyword')
  const [syncConfirmed, setSyncConfirmed] = useState(false)
  const [followupMessage, setFollowupMessage] = useState<string | null>(null)
  const [writebackResult, setWritebackResult] = useState<WritebackResult | null>(null)

  const writebackMutation = useMutation({
    mutationFn: () => cullingApi.writeback(sessionId, selected),
    onSuccess: (result) => {
      setWritebackResult(result)
      setSyncConfirmed(false)
      setFollowupMessage(null)
    },
  })

  const retryMutation = useMutation({
    mutationFn: () => cullingApi.retryFailedWriteback(sessionId),
    onSuccess: (result) => setWritebackResult(result),
  })

  const handleConfirmSync = async () => {
    try {
      await cullingApi.confirmSync(sessionId)
      setSyncConfirmed(true)
      setFollowupMessage('已确认 Capture One 完成“加载元数据”，现在可以清理。')
    } catch (error) {
      setFollowupMessage(`确认失败：${error instanceof Error ? error.message : '未知错误'}`)
    }
  }

  const handleCleanup = async () => {
    try {
      const result = await cullingApi.cleanup(sessionId)
      setFollowupMessage(`清理完成：已恢复或移除 ${result.deletedCount} 个 sidecar 文件。`)
    } catch (error) {
      setFollowupMessage(`清理失败：${error instanceof Error ? error.message : '未知错误'}`)
    }
  }

  const options: { value: 'rating' | 'color_label' | 'keyword'; label: string; desc: string }[] = [
    { value: 'rating', label: '星级', desc: '保留写入 5 星，淘汰写入 1 星' },
    { value: 'color_label', label: '颜色标签', desc: '保留写入绿色，淘汰写入红色' },
    { value: 'keyword', label: '关键词', desc: '写入 culling:keep 或 culling:reject 关键词' },
  ]

  return (
    <div className={styles.dialog} onClick={onClose}>
      <div className={styles.dialogContent} onClick={(e) => e.stopPropagation()}>
        <div className={styles.dialogTitle}>选择写回内容</div>
        <div className={styles.dialogBody}>
          {options.map((opt) => (
            <div
              key={opt.value}
              className={`${styles.dialogOption} ${selected === opt.value ? styles.dialogOptionSelected : ''}`}
              onClick={() => setSelected(opt.value)}
            >
              <div>
                <div className={styles.dialogOptionLabel}>{opt.label}</div>
                <div className={styles.dialogOptionDesc}>{opt.desc}</div>
              </div>
            </div>
          ))}
        </div>
        <div className={styles.dialogActions}>
          <button className={styles.dialogBtn} onClick={onClose}>
            {writebackResult ? '完成' : '取消'}
          </button>
          <button
            className={`${styles.dialogBtn} ${styles.dialogBtnPrimary}`}
            onClick={() => writebackMutation.mutate()}
            disabled={writebackMutation.isPending || writebackResult !== null}
          >
            {writebackMutation.isPending ? '正在写回...' : '开始写回'}
          </button>
        </div>
        {writebackMutation.isError && (
          <p style={{ color: '#ef5350', marginTop: 12, fontSize: 13 }}>
            {writebackMutation.error instanceof Error ? writebackMutation.error.message : '写回失败'}
          </p>
        )}
        {writebackResult && (
          <div style={{ color: '#4caf50', marginTop: 12, fontSize: 13 }}>
            <p style={{ margin: 0 }}>
              XMP 写入完成：成功 {writebackResult.written}，失败 {writebackResult.failed}，跳过 {writebackResult.skipped}。
            </p>
            {writebackResult.errors.length > 0 && (
              <ul style={{ color: '#ef5350', paddingLeft: 18 }}>
                {writebackResult.errors.map((error, index) => (
                  <li key={`${index}-${error}`}>{error}</li>
                ))}
              </ul>
            )}
            <p style={{ color: '#a0a0a0', marginBottom: 0 }}>
              请在 Capture One 中选择照片并执行“图像 → 加载元数据”。
            </p>
            <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
              {writebackResult.failed > 0 && (
                <button
                  className={styles.dialogBtn}
                  onClick={() => retryMutation.mutate()}
                  disabled={retryMutation.isPending}
                >
                  {retryMutation.isPending ? '重试中...' : '重试失败项'}
                </button>
              )}
              <button
                className={styles.dialogBtn}
                onClick={() => void handleConfirmSync()}
                disabled={writebackResult.failed > 0}
              >
                确认同步
              </button>
              {syncConfirmed && (
                <button className={styles.dialogBtn} onClick={() => void handleCleanup()}>
                  清理
                </button>
              )}
            </div>
            {followupMessage && (
              <p style={{ color: '#a0a0a0', marginBottom: 0 }}>{followupMessage}</p>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

export default function Culling() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const queryClient = useQueryClient()

  const [currentGroupIndex, setCurrentGroupIndex] = useState(0)
  const [currentPhotoIndex, setCurrentPhotoIndex] = useState(0)
  const [showWriteback, setShowWriteback] = useState(false)

  const { data: groups, isLoading } = useQuery({
    queryKey: ['culling', 'groups', sessionId],
    queryFn: () => cullingApi.getGroups(sessionId!),
    enabled: !!sessionId,
  })

  const { data: summary } = useQuery({
    queryKey: ['culling', 'summary', sessionId],
    queryFn: () => cullingApi.getSummary(sessionId!),
    enabled: !!sessionId,
  })

  useEffect(() => {
    setCurrentPhotoIndex(0)
  }, [currentGroupIndex])

  const goToGroup = useCallback((index: number) => {
    if (groups && index >= 0 && index < groups.length) {
      setCurrentGroupIndex(index)
    }
  }, [groups])

  const nextGroup = useCallback(() => {
    setCurrentGroupIndex((i) => (groups && i < groups.length - 1) ? i + 1 : i)
  }, [groups])

  const prevGroup = useCallback(() => {
    setCurrentGroupIndex((i) => i > 0 ? i - 1 : i)
  }, [])

  const decideMutation = useMutation({
    mutationFn: ({ photoId, decision }: { photoId: string; decision: 'keep' | 'reject' | 'pending' }) =>
      cullingApi.decide(sessionId!, photoId, decision),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['culling'] })
    },
  })

  const currentGroup = groups?.[currentGroupIndex] ?? null
  const currentPhoto = currentGroup?.images[currentPhotoIndex] ?? null

  const handleDecide = useCallback(
    (decision: 'keep' | 'reject' | 'pending') => {
      if (!currentPhoto?.photoId || !sessionId) return
      decideMutation.mutate({ photoId: currentPhoto.photoId, decision })
    },
    [currentPhoto, sessionId, decideMutation],
  )

  const goToPhoto = useCallback(
    (index: number) => {
      if (currentGroup && index >= 0 && index < currentGroup.images.length) {
        setCurrentPhotoIndex(index)
      }
    },
    [currentGroup],
  )

  const goToNextPhoto = useCallback(() => {
    if (currentGroup && currentPhotoIndex < currentGroup.images.length - 1) {
      setCurrentPhotoIndex((i) => i + 1)
    }
  }, [currentGroup, currentPhotoIndex])

  const goToPrevPhoto = useCallback(() => {
    if (currentPhotoIndex > 0) {
      setCurrentPhotoIndex((i) => i - 1)
    }
  }, [currentPhotoIndex])

  const handleDecideRef = useRef(handleDecide)
  const goToPrevPhotoRef = useRef(goToPrevPhoto)
  const goToNextPhotoRef = useRef(goToNextPhoto)
  const prevGroupRef = useRef(prevGroup)
  const nextGroupRef = useRef(nextGroup)

  useEffect(() => {
    handleDecideRef.current = handleDecide
    goToPrevPhotoRef.current = goToPrevPhoto
    goToNextPhotoRef.current = goToNextPhoto
    prevGroupRef.current = prevGroup
    nextGroupRef.current = nextGroup
  })

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (showWriteback) return

      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return

      switch (e.key) {
        case 'y':
        case 'Y':
          e.preventDefault()
          handleDecideRef.current('keep')
          break
        case 'n':
        case 'N':
          e.preventDefault()
          handleDecideRef.current('reject')
          break
        case ' ':
          e.preventDefault()
          handleDecideRef.current('pending')
          break
        case 'ArrowLeft':
          e.preventDefault()
          goToPrevPhotoRef.current()
          break
        case 'ArrowRight':
          e.preventDefault()
          goToNextPhotoRef.current()
          break
        case 'Tab':
          e.preventDefault()
          if (e.shiftKey) {
            prevGroupRef.current()
          } else {
            nextGroupRef.current()
          }
          break
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [showWriteback])

  if (!sessionId) {
    return <div className={styles.page}><div className={styles.emptyState}>未选择工作区</div></div>
  }

  if (isLoading) {
    return <div className={styles.page}><div className={styles.emptyState}>正在加载...</div></div>
  }

  if (!groups || groups.length === 0) {
    return (
      <div className={styles.page}>
        <div className={styles.emptyState}>
          暂无相似照片组，请先运行相似度分析。
        </div>
      </div>
    )
  }

  const hasDecisions = currentGroup
    ? currentGroup.keepCount + currentGroup.rejectCount > 0
    : false

  const decisionBadgeClass = currentPhoto
    ? currentPhoto.decision === 'keep'
      ? styles.badgeKeep
      : currentPhoto.decision === 'reject'
        ? styles.badgeReject
        : styles.badgePending
    : ''

  const decisionLabel = currentPhoto
    ? currentPhoto.decision === 'keep'
      ? '保留'
      : currentPhoto.decision === 'reject'
        ? '淘汰'
        : '待处理'
    : ''

  return (
    <div className={styles.page}>
      <div className={styles.mainViewer}>
        {currentPhoto ? (
          <>
            {currentPhotoIndex > 0 && (
              <button className={`${styles.navBtn} ${styles.navPrev}`} onClick={goToPrevPhoto}>
                ‹
              </button>
            )}
            {currentPhoto.decision !== 'pending' && (
              <div className={`${styles.decisionBadge} ${decisionBadgeClass}`}>{decisionLabel}</div>
            )}
            <ViewerImage path={currentPhoto.filepath} className={styles.mainImage} />
            {currentPhotoIndex < currentGroup!.images.length - 1 && (
              <button className={`${styles.navBtn} ${styles.navNext}`} onClick={goToNextPhoto}>
                ›
              </button>
            )}
          </>
        ) : (
          <div className={styles.mainPlaceholder}>暂无照片</div>
        )}
      </div>

      {currentGroup && (
        <div className={styles.progressBar}>
          <div className={styles.progressLeft}>
            <span>第 {currentGroupIndex + 1} 组，共 {groups!.length} 组</span>
            <div className={styles.progressBarFill}>
              <div
                className={styles.progressBarInner}
                style={{ width: `${((currentGroupIndex + 1) / groups!.length) * 100}%` }}
              />
            </div>
          </div>
          <div className={styles.progressRight}>
            <span className={styles.statKeep}>保留 {currentGroup.keepCount}</span>
            <span className={styles.statReject}>淘汰 {currentGroup.rejectCount}</span>
            <span className={styles.statPending}>待定 {currentGroup.pendingCount}</span>
            <span className={styles.shortcutHint}>快捷键 Y / N / 空格</span>
          </div>
        </div>
      )}

      {currentGroup && (
        <div className={styles.filmstrip}>
          {currentGroup.images.map((img, idx) => (
            <div
              key={img.photoId || idx}
              className={`${styles.filmstripItem} ${idx === currentPhotoIndex ? styles.filmstripItemActive : ''}`}
              onClick={() => goToPhoto(idx)}
            >
              <ThumbnailImg path={img.filepath} className={styles.filmstripImg} />
              <div
                className={`${styles.filmstripBadge} ${
                  img.decision === 'keep'
                    ? styles.filmstripBadgeKeep
                    : img.decision === 'reject'
                      ? styles.filmstripBadgeReject
                      : styles.filmstripBadgePending
                }`}
              />
            </div>
          ))}
        </div>
      )}

      <div className={styles.controls}>
        <button className={`${styles.controlBtn} ${styles.btnKeep}`} onClick={() => handleDecide('keep')}>
          保留（Y）
        </button>
        <button className={`${styles.controlBtn} ${styles.btnReject}`} onClick={() => handleDecide('reject')}>
          淘汰（N）
        </button>
        <button className={styles.controlBtn} onClick={() => handleDecide('pending')}>
          待定（空格）
        </button>
        <button className={styles.controlBtn} onClick={prevGroup} disabled={currentGroupIndex === 0}>
          上一组
        </button>
        <button className={styles.controlBtn} onClick={nextGroup} disabled={currentGroupIndex >= groups!.length - 1}>
          下一组（Tab）
        </button>
        {hasDecisions && (
          <button className={`${styles.controlBtn} ${styles.btnWriteback}`} onClick={() => setShowWriteback(true)}>
            写回 XMP
          </button>
        )}
      </div>

      {showWriteback && (
        <WritebackDialog
          sessionId={sessionId}
          onClose={() => setShowWriteback(false)}
        />
      )}
    </div>
  )
}
