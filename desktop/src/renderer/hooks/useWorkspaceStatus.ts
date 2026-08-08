import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { workspaceApi } from '../api/workspace'
import { useEvent } from './useEvent'
import type { WorkspaceStatus } from '@gather/shared'

const WORKSPACE_STATUS_QUERY_KEY = 'workspace-status'
// 轮询兜底（design_improvements.md 1.5：轮询 30s/3s + 事件推送为即时刷新）。
// 普通状态 30s 一次；索引 job 活跃时降为 3s 以便索引进度条及时推进。
const POLL_INTERVAL_MS = 30_000
const POLL_INTERVAL_ACTIVE_MS = 3_000

/**
 * 工作区状态聚合查询（design_improvements.md 1.4.3）。刷新策略：
 * - react-query 轮询兜底（30s 常规 / 3s 索引活跃期）；
 * - 即时刷新复用现有推送事件，不新增 push 通道：
 *   - `jobs:progress` 任意 jobType 的终态帧（status 存在）都会触发重查——
 *     索引、分析、导出等任一 job 结束都可能是 stage/softFlags/
 *     staleAnalyses 的跳变点；索引活跃标记只由 metadata.scan 帧驱动；
 *   - `culling:sync-status` 覆盖 XMP 行状态迁移（pending/written/failed/
 *     conflict/synced），即 xmp 计数的跳变点。
 *   普通进度帧不触发重查（高频），进度数值由 3s 轮询兜底。
 */
export function useWorkspaceStatus(sessionId: string) {
  const queryClient = useQueryClient()
  const [indexActive, setIndexActive] = useState(false)

  useEvent('jobs:progress', (payload) => {
    const data = payload as {
      jobType?: string
      scopeId?: string
      status?: string
    }
    if (data.scopeId !== sessionId) return
    if (data.status) {
      // 任意 jobType 的终态帧都触发重查（索引/分析/导出完成都可能改变
      // stage / softFlags / staleAnalyses）；活跃轮询只随 metadata.scan 复位。
      if (data.jobType === 'metadata.scan') setIndexActive(false)
      queryClient.invalidateQueries({ queryKey: [WORKSPACE_STATUS_QUERY_KEY, sessionId] })
    } else if (data.jobType === 'metadata.scan') {
      setIndexActive(true)
    }
  })

  useEvent('culling:sync-status', (payload) => {
    const data = payload as { sessionId?: string }
    if (data.sessionId !== sessionId) return
    queryClient.invalidateQueries({ queryKey: [WORKSPACE_STATUS_QUERY_KEY, sessionId] })
  })

  return useQuery<WorkspaceStatus>({
    queryKey: [WORKSPACE_STATUS_QUERY_KEY, sessionId],
    queryFn: () => workspaceApi.status(sessionId),
    refetchInterval: indexActive ? POLL_INTERVAL_ACTIVE_MS : POLL_INTERVAL_MS,
  })
}
